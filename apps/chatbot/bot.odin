package main

// The brain, and all of it pure.
//
// Everything in this file is a procedure from values to values: given a
// message, decide what to do; given a list of messages, build the context;
// given a clock and a growing string, decide whether it is time to edit. No
// sockets, no globals, no clock of its own. That is what lets the self-test
// cover the parts that actually matter — the self-reply guard, the context
// cap and the coalescing policy — without a server or a model anywhere near
// it.

import "core:fmt"
import "core:strconv"
import "core:strings"
import w "../chat/wire"

// ---------------------------------------------------------------------------
// Identity
//
// The nickname says it is a model and the footer on every reply says which
// one. qwen3:0.6b is half a gigabyte: it is quick, it is frequently wrong,
// and a bot that implies otherwise is worse than no bot.
// ---------------------------------------------------------------------------

MODEL_DEFAULT :: "qwen3:0.6b"
BOT_NICK_DEFAULT :: "qwen3-bot"

// The aliases a mention may use. The nick itself is always one of them; `bot`
// is here because it is what people type.
MENTION_ALIASES :: [2]string{"bot", "ai"}

// ---------------------------------------------------------------------------
// Caps
// ---------------------------------------------------------------------------

// How far back the bot looks, and how much of it travels to the model. Both
// caps apply: whichever trips first wins. 20 messages and 6000 bytes of
// conversation is about four screens of chat and roughly 1500 tokens of
// prompt, which a 0.6B model with a 40k window handles without thinking about
// it, and which bounds what one mention can cost.
CTX_MAX_MSGS :: 20
CTX_MAX_BYTES :: 6000

// One context line is truncated at this many bytes, so a single pasted wall
// of text cannot eat the whole window on its own.
CTX_MAX_LINE :: 1200

// The server refuses a post over 4000 bytes (`MAX_TEXT`). A reply is clipped
// well inside that, with room for the footer, because an edit that is refused
// leaves the channel showing a half-written answer forever.
MAX_POST :: 4000
POST_BUDGET :: 3600

// At most this many tokens per reply. A 0.6B model at ~120 tok/s reaches it
// in about four seconds, and 512 tokens cannot overflow POST_BUDGET.
NUM_PREDICT :: 512

// ---------------------------------------------------------------------------
// Mentions
// ---------------------------------------------------------------------------

// ident_byte is the character class a mention token is made of. A mention
// must be bounded by something outside it on both sides, so "@bot" matches in
// "@bot hello" and "hey @bot," but not in "sand@bottle" or "@bottle".
ident_byte :: proc(c: u8) -> bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	case c == '-', c == '_', c == '.', c == ':':
		return true
	}
	return false
}

// mention_split finds the first `@alias` in `text`, removes it, and returns
// what is left. `found` is false when the text does not address this bot at
// all, which is the common case and the reason the bot is quiet.
mention_split :: proc(
	text: string,
	nick: string,
	allocator := context.temp_allocator,
) -> (
	rest: string,
	found: bool,
) {
	aliases := MENTION_ALIASES
	for i in 0 ..< len(text) {
		if text[i] != '@' {
			continue
		}
		if i > 0 && ident_byte(text[i - 1]) {
			continue
		}
		tail := text[i + 1:]
		hit := 0
		if mention_head(tail, nick) {
			hit = len(nick)
		} else {
			for a in aliases {
				if mention_head(tail, a) {
					hit = len(a)
					break
				}
			}
		}
		if hit == 0 {
			continue
		}
		// Join what was on either side of the mention with exactly one space,
		// so "hey @bot, what?" becomes "hey , what?" rather than carrying the
		// hole the token left behind.
		head := strings.trim_right_space(text[:i])
		rest_ := strings.trim_left_space(tail[hit:])
		if head == "" {
			return rest_, true
		}
		if rest_ == "" {
			return head, true
		}
		b := strings.builder_make(allocator)
		strings.write_string(&b, head)
		strings.write_byte(&b, ' ')
		strings.write_string(&b, rest_)
		return strings.to_string(b), true
	}
	return "", false
}

@(private = "file")
mention_head :: proc(tail, alias: string) -> bool {
	if len(alias) == 0 || len(tail) < len(alias) {
		return false
	}
	if !strings.equal_fold(tail[:len(alias)], alias) {
		return false
	}
	// A trailing ident byte means this is a longer word that merely starts
	// the same way: "@bottle" is not "@bot".
	if len(tail) > len(alias) && ident_byte(tail[len(alias)]) {
		return false
	}
	return true
}

// ---------------------------------------------------------------------------
// The decision
// ---------------------------------------------------------------------------

Act :: enum u8 {
	Ignore,
	Ask, // a free-form question
	Summarise, // summarise the recent conversation
	Explain, // explain or expand on one message by id
	Stop, // cancel whatever is being generated
	Help,
	Bad_Id, // "explain" with no usable id: answer with the complaint, not the model
}

Action :: struct {
	act:    Act,
	ch:     string,
	thread: i64, // the thread to answer in, 0 for the channel timeline
	asker:  string,
	src:    i64, // the message that triggered this
	prompt: string, // for .Ask
	target: i64, // for .Explain
}

// decide is the guard, and it is the only one. Its first statement is the
// self-reply check, so there is no path through this procedure on which the
// bot can answer itself: a message it wrote is `.Ignore` before the text has
// even been looked at. Its second property is that nothing but a mention —
// or a DM, where every message is addressed by construction — can produce a
// non-`.Ignore` action, so it cannot answer every message either.
decide :: proc(
	bot_nick: string,
	m: w.Msg,
	allocator := context.temp_allocator,
) -> Action {
	if m.nick == bot_nick {
		return Action{act = .Ignore}
	}
	if m.deleted || strings.trim_space(m.text) == "" {
		return Action{act = .Ignore}
	}

	body := ""
	addressed := false
	if w.dm_has(m.ch, bot_nick) {
		// A DM channel's name is the two participants joined with `+`, so a
		// message in one that this bot can see is addressed to it by
		// definition. The `@` is optional there.
		body, addressed = mention_split(m.text, bot_nick, allocator)
		if !addressed {
			body = strings.trim_space(m.text)
			addressed = true
		}
	} else {
		body, addressed = mention_split(m.text, bot_nick, allocator)
	}
	if !addressed {
		return Action{act = .Ignore}
	}

	a := Action {
		ch     = m.ch,
		thread = m.thread,
		asker  = m.nick,
		src    = m.id,
	}

	word, rest := first_word(body)
	switch strings.to_lower(word, allocator) {
	case "":
		a.act = .Help
	case "help", "commands", "?":
		a.act = .Help
	case "stop", "cancel", "quiet", "halt":
		a.act = .Stop
	case "summarise", "summarize", "summary", "tldr", "recap":
		a.act = .Summarise
	case "explain", "expand", "unpack":
		// `explain 41` is the command; `explain how a rasterizer works` is an
		// ordinary question that happens to start with the same word. Only an
		// id makes it the command, and only a bare "explain" with nothing
		// after it is worth complaining about.
		if id, ok := parse_msg_id(rest); ok {
			a.act = .Explain
			a.target = id
		} else if rest == "" {
			a.act = .Bad_Id
		} else {
			a.act = .Ask
			a.prompt = body
		}
	case:
		a.act = .Ask
		a.prompt = body
	}
	return a
}

first_word :: proc(s: string) -> (word, rest: string) {
	t := strings.trim_space(s)
	for i in 0 ..< len(t) {
		if t[i] == ' ' || t[i] == '\t' || t[i] == '\n' {
			return t[:i], strings.trim_space(t[i:])
		}
	}
	return t, ""
}

// parse_msg_id accepts "41", "#41" and "id 41" — the three ways somebody
// reads an id off a screen and types it back.
parse_msg_id :: proc(s: string) -> (id: i64, ok: bool) {
	t := strings.trim_space(s)
	if strings.has_prefix(t, "id ") || strings.has_prefix(t, "ID ") {
		t = strings.trim_space(t[3:])
	}
	t = strings.trim_left(t, "#")
	w2, _ := first_word(t)
	n, good := strconv.parse_i64(w2)
	if !good || n <= 0 {
		return 0, false
	}
	return n, true
}

// ---------------------------------------------------------------------------
// The context window
// ---------------------------------------------------------------------------

// context_turns turns a run of chat messages into the turns sent to the
// model, newest-last, under both caps. It walks backwards so that when the
// byte cap trips it is the *oldest* context that is dropped, and it never
// emits a partial turn.
//
// The bot's own messages become `assistant` turns, so the model sees its own
// previous answers as its own rather than as somebody quoting it. Everyone
// else becomes a `user` turn prefixed with the nickname, which is how a
// single-user role gets to carry a multi-party conversation.
context_turns :: proc(
	msgs: []w.Msg,
	bot_nick: string,
	max_msgs := CTX_MAX_MSGS,
	max_bytes := CTX_MAX_BYTES,
	allocator := context.temp_allocator,
) -> []Turn {
	picked := make([dynamic]Turn, allocator)
	bytes := 0
	for i := len(msgs) - 1; i >= 0; i -= 1 {
		if len(picked) >= max_msgs {
			break
		}
		m := msgs[i]
		if m.deleted || strings.trim_space(m.text) == "" {
			continue
		}
		body := clip_utf8(strings.trim_space(m.text), CTX_MAX_LINE)
		line := body
		role := Turn_Role.Assistant
		if m.nick != bot_nick {
			role = .User
			line = fmt.aprintf("%s: %s", m.nick, body, allocator = allocator)
		} else {
			// A reply of the bot's own carries its footer; the model does not
			// need to be taught to imitate it.
			line = strip_footer(body, allocator)
		}
		if bytes + len(line) > max_bytes && len(picked) > 0 {
			break
		}
		bytes += len(line)
		append(&picked, Turn{role = role, text = line})
	}
	// Reverse into chronological order.
	out := make([]Turn, len(picked), allocator)
	for t, i in picked {
		out[len(picked) - 1 - i] = t
	}
	return out
}

// context_bytes is what the caps are measured against, and what the self-test
// asserts never exceeds CTX_MAX_BYTES by more than one line.
context_bytes :: proc(turns: []Turn) -> int {
	n := 0
	for t in turns {
		n += len(t.text)
	}
	return n
}

// clip_utf8 truncates to at most `n` bytes without splitting a UTF-8
// sequence: it walks back off any continuation byte.
clip_utf8 :: proc(s: string, n: int) -> string {
	if len(s) <= n {
		return s
	}
	cut := n
	for cut > 0 && (s[cut] & 0xC0) == 0x80 {
		cut -= 1
	}
	return s[:cut]
}

// ---------------------------------------------------------------------------
// What a reply looks like on the wire
// ---------------------------------------------------------------------------

FOOTER_MARK :: "\n\n*— "

// footer is on every reply, in every state, because a reader who scrolls past
// the first line still has to know a half-gigabyte model wrote it.
footer :: proc(model: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"%s%s, a local %s model: fast, and often wrong.*",
		FOOTER_MARK,
		model,
		"0.5 GB",
		allocator = allocator,
	)
}

// strip_footer removes the attribution from the bot's own text before it goes
// back into a prompt.
strip_footer :: proc(s: string, allocator := context.temp_allocator) -> string {
	if i := strings.index(s, FOOTER_MARK); i >= 0 {
		return strings.clone(strings.trim_space(s[:i]), allocator)
	}
	if i := strings.index(s, "\n\n*…"); i >= 0 {
		return strings.clone(strings.trim_space(s[:i]), allocator)
	}
	return s
}

// render_reply assembles the text that will be posted or edited in. Three
// states, all carrying the model name:
//
//   * nothing yet      — "qwen3:0.6b is reading the channel…"
//   * streaming        — the partial answer, with a writing marker
//   * done / stopped   — the answer, with the attribution footer
//
// It is also the one place the server's size limit is enforced, by clipping
// the body rather than the footer: a reply that loses its attribution to a
// length cap would be the one case where the bot looks like a person.
render_reply :: proc(
	body: string,
	model: string,
	done: bool,
	stopped: bool,
	allocator := context.temp_allocator,
) -> string {
	trimmed := strings.trim_space(body)
	if !done && trimmed == "" {
		return fmt.aprintf("*%s is reading the channel…*", model, allocator = allocator)
	}
	tail := done ? footer(model, allocator) : fmt.aprintf("\n\n*… %s*", model, allocator = allocator)
	if done && stopped {
		tail = fmt.aprintf("\n\n*stopped.*%s", footer(model, allocator), allocator = allocator)
	}
	if done && trimmed == "" {
		trimmed = "*(no answer — the model produced nothing)*"
	}
	budget := min(POST_BUDGET, MAX_POST - len(tail) - 16)
	kept := clip_utf8(trimmed, budget)
	cut := len(kept) < len(trimmed)

	b := strings.builder_make(allocator)
	strings.write_string(&b, kept)
	if cut {
		strings.write_string(&b, " …")
	}
	strings.write_string(&b, tail)
	out := strings.to_string(b)
	assert(len(out) <= MAX_POST, "a rendered reply must fit the server's message limit")
	return out
}

// no_ollama_text is what goes in the channel when the model is not reachable.
// It names the exact command, because "the backend is unavailable" is not
// something anybody can act on.
no_ollama_text :: proc(model: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"I cannot answer right now: **ollama is not running** on this machine, so there is no %s to ask.\n\nStart it with:\n\n```\n%s\n```\n%s",
		model,
		OLLAMA_START_HINT,
		footer(model, allocator),
		allocator = allocator,
	)
}

help_text :: proc(nick, model: string, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"I am **@%s** — a bot wrapped around `%s`, the local model on this machine. Mention me and I answer in this channel, or in this thread if you ask me inside one.\n\n- `@%s <question>` — ask me something; I read the last %d messages here as context\n- `@%s summarise` — summarise the recent conversation\n- `@%s explain <id>` — explain or expand on one message, by its id\n- `@%s stop` — abandon whatever I am writing\n%s",
		nick,
		model,
		nick,
		CTX_MAX_MSGS,
		nick,
		nick,
		nick,
		footer(model, allocator),
		allocator = allocator,
	)
}

// ---------------------------------------------------------------------------
// Prompts
// ---------------------------------------------------------------------------

system_prompt :: proc(nick, model, ch: string, in_thread: bool, allocator := context.temp_allocator) -> string {
	where_ := in_thread ? "thread" : "channel"
	return fmt.aprintf(
		"You are %s, a bot in a small team chat, speaking in the %s %q. You are the local model %s and you say so plainly if anyone asks what you are. Answer only the last message addressed to you; the rest is context. Be brief: at most 120 words, plain prose or a short markdown list, no headings. Never invent facts about these people or their work. If you do not know, say so in one line.",
		nick,
		where_,
		ch,
		model,
		allocator = allocator,
	)
}

SUMMARISE_PROMPT :: "Summarise the conversation above in at most five short bullet points, naming who said what. Add nothing that is not in it. If there is too little to summarise, say so in one line."

explain_prompt :: proc(m: w.Msg, allocator := context.temp_allocator) -> string {
	return fmt.aprintf(
		"Message %d in this channel, from %s, says:\n\n\"%s\"\n\nExplain and expand on it in at most 120 words, for somebody who has just joined. If it is too short or too vague to explain, say that instead of guessing.",
		m.id,
		m.nick,
		clip_utf8(strings.trim_space(m.text), CTX_MAX_LINE),
		allocator = allocator,
	)
}

// ---------------------------------------------------------------------------
// Coalescing: how often the channel is told what the model has said so far
// ---------------------------------------------------------------------------

// The policy, and the reasoning behind the numbers.
//
// ollama emits one NDJSON object per token. An `edit` per token would be a
// broadcast per token to every connected client — several hundred frames, all
// inside the server's one mutex, for one answer. That is a denial of service
// written by hand, and it is the obvious thing to build.
//
// So: an edit lands at most every `min_ms`, and only once `min_chars` of new
// text have arrived. On top of that, a sentence that *just finished* flushes
// early, after only `sentence_ms`, because a paragraph appearing whole reads
// far better than one appearing mid-clause — that is the one case where the
// extra broadcast buys something.
//
// The cost is latency: a token can sit unpublished for up to `min_ms`, so the
// reply trails the model by up to three quarters of a second. For a reply
// that takes five to thirty seconds that is invisible, and it turns several
// hundred broadcasts into roughly one and a half per second of generation.
Coalesce :: struct {
	min_ms:      i64,
	min_chars:   int,
	sentence_ms: i64,
	sentence_chars: int,
}

COALESCE :: Coalesce {
	min_ms         = 700,
	min_chars      = 24,
	sentence_ms    = 350,
	sentence_chars = 8,
}

// Flow is the published state: when the last edit went out and how long the
// text was at that point.
Flow :: struct {
	last_ms:  i64,
	last_len: int,
	edits:    int,
}

ends_sentence :: proc(s: string) -> bool {
	i := len(s) - 1
	for i >= 0 && (s[i] == ' ' || s[i] == '\t') {
		i -= 1
	}
	if i < 0 {
		return false
	}
	switch s[i] {
	case '.', '!', '?', ':', '\n', ';':
		return true
	}
	return false
}

// coalesce_due is the whole policy, as a pure function of the clock and the
// text. The self-test replays a token stream through it and counts.
coalesce_due :: proc(p: Coalesce, f: Flow, now_ms: i64, text: string, done: bool) -> bool {
	if done {
		return true
	}
	grown := len(text) - f.last_len
	if grown <= 0 {
		return false
	}
	since := now_ms - f.last_ms
	if grown >= p.sentence_chars && since >= p.sentence_ms && ends_sentence(text) {
		return true
	}
	return since >= p.min_ms && grown >= p.min_chars
}

// ---------------------------------------------------------------------------
// Rate limiting
// ---------------------------------------------------------------------------

// Two limits, for two different failures. `min_gap_ms` stops a burst of
// mentions turning into a burst of generations, and `max_per_min` bounds what
// the bot can cost over a minute however it is provoked. Together with
// `decide`'s self-reply guard and one generation in flight at a time, a loop
// cannot run away: even if something did start answering itself, it would do
// so at most `max_per_min` times a minute and the loop would be visible
// rather than fatal.
Limiter :: struct {
	min_gap_ms:  i64,
	max_per_min: int,
	last_ms:     i64,
	window_ms:   i64,
	in_window:   int,
	started:     bool,
}

limiter_make :: proc(min_gap_ms: i64 = 1200, max_per_min := 12) -> Limiter {
	return Limiter{min_gap_ms = min_gap_ms, max_per_min = max_per_min}
}

limiter_allow :: proc(l: Limiter, now_ms: i64) -> (ok: bool, why: string) {
	if l.started && now_ms - l.last_ms < l.min_gap_ms {
		return false, "too soon after the last reply"
	}
	n := l.in_window
	if l.started && now_ms - l.window_ms >= 60_000 {
		n = 0
	}
	if n >= l.max_per_min {
		return false, "the per-minute reply budget is spent"
	}
	return true, ""
}

limiter_note :: proc(l: ^Limiter, now_ms: i64) {
	if !l.started || now_ms - l.window_ms >= 60_000 {
		l.window_ms = now_ms
		l.in_window = 0
	}
	l.in_window += 1
	l.last_ms = now_ms
	l.started = true
}
