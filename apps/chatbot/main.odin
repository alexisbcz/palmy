package main

// palmy-chatbot — the local model as a chat participant.
//
// A separate process that joins the palmy-chat server as an ordinary client,
// watches for mentions, and answers by streaming a reply from ollama into a
// message it owns.
//
// Two sockets, one loop, no threads:
//
//   * the chat server on 127.0.0.1:8787, non-blocking, drained every pass;
//   * ollama on 127.0.0.1:11434, with a 200ms receive timeout, pumped only
//     while a reply is being generated.
//
// The loop alternates between them, which is why cancellation is bounded by
// one ollama read and why nothing in this program needs a mutex.
//
// WHAT IT WILL NOT DO. It reads channel messages because that is how it
// answers them, and that is the whole of what it does with them: nothing here
// writes a message to a file, prints one to a log, or sends one anywhere but
// 127.0.0.1:11434. `note` takes ids, counts and nicknames; it has never been
// given a `text`.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import w "../chat/wire"

VERSION :: "1.0"

Args :: struct {
	port:        int,
	nick:        string,
	model:       string,
	channels:    [dynamic]string,
	server:      string, // the server binary, for --e2e
	selftest:    bool,
	e2e:         bool,
	quiet:       bool,
	max_replies: int, // 0 = no limit
}

QUEUE_MAX :: 4

Job :: struct {
	live:      bool,
	act:       Action,
	gen:       Gen,
	msg_id:    i64, // the message the bot owns and keeps editing
	flow:      Flow,
	published: string, // the last text actually sent, so an edit is never a no-op
	bcasts:    int, // the post, plus every edit: what this reply cost everyone
	started:   i64,
}

Bot :: struct {
	args:    Args,
	link:    Link,
	cache:   Cache,
	lim:     Limiter,
	queue:   [dynamic]Action,
	job:     Job,
	replies: int,
	dropped: int,
	joined:  map[string]bool,
	seeded:  bool,
	ollama_warned_ms: i64,
}

bot: Bot

note :: proc(format: string, args: ..any) {
	if bot.args.quiet {
		return
	}
	fmt.eprintf("[chatbot] %s\n", fmt.tprintf(format, ..args))
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------

main :: proc() {
	bot.args = parse_args()

	if bot.args.selftest {
		os.exit(run_selftest())
	}
	if bot.args.e2e {
		os.exit(run_e2e(bot.args))
	}
	os.exit(run(bot.args))
}

parse_args :: proc() -> Args {
	out := Args {
		port        = w.DEFAULT_PORT,
		nick        = BOT_NICK_DEFAULT,
		model       = MODEL_DEFAULT,
		channels    = make([dynamic]string),
	}
	i := 1
	for i < len(os.args) {
		a := os.args[i]
		switch a {
		case "--port":
			if i + 1 < len(os.args) {
				if n, ok := strconv.parse_int(os.args[i + 1]); ok {
					out.port = n
				}
				i += 1
			}
		case "--nick":
			if i + 1 < len(os.args) {
				out.nick = os.args[i + 1]
				i += 1
			}
		case "--model":
			if i + 1 < len(os.args) {
				out.model = os.args[i + 1]
				i += 1
			}
		case "--channel", "--channels":
			if i + 1 < len(os.args) {
				for c in strings.split(os.args[i + 1], ",", context.allocator) {
					t := strings.trim_space(c)
					if t != "" {
						append(&out.channels, t)
					}
				}
				i += 1
			}
		case "--server":
			if i + 1 < len(os.args) {
				out.server = os.args[i + 1]
				i += 1
			}
		case "--max-replies":
			if i + 1 < len(os.args) {
				if n, ok := strconv.parse_int(os.args[i + 1]); ok {
					out.max_replies = n
				}
				i += 1
			}
		case "--selftest":
			out.selftest = true
		case "--e2e":
			out.e2e = true
		case "--quiet", "-q":
			out.quiet = true
		case "--help", "-h":
			usage()
			os.exit(0)
		case:
			fmt.eprintfln("chatbot: unknown argument %q (try --help)", a)
			os.exit(2)
		}
		i += 1
	}
	if len(out.channels) == 0 {
		append(&out.channels, "general")
	}
	return out
}

usage :: proc() {
	fmt.println("palmy-chatbot — the local model as a chat participant")
	fmt.println()
	fmt.println("usage: chatbot.bin [options]")
	fmt.println()
	fmt.println("  --port N          chat server port (default 8787, loopback only)")
	fmt.printfln("  --nick NAME       the bot's nickname (default %s)", BOT_NICK_DEFAULT)
	fmt.printfln("  --model NAME      the ollama model (default %s)", MODEL_DEFAULT)
	fmt.println("  --channels a,b     channels to make sure exist and join")
	fmt.println("  --max-replies N   exit after N replies (0 = never)")
	fmt.println("  --selftest        headless tests: no chat server, no model")
	fmt.println("  --e2e             end-to-end: spawn a server, a bot and a client")
	fmt.println("  --quiet           no progress on stderr")
	fmt.println()
	fmt.printfln("ollama is reached at %s:%d and nowhere else.", OLLAMA_HOST, OLLAMA_PORT)
	fmt.printfln("If it is not running:  %s", OLLAMA_START_HINT)
}

// ---------------------------------------------------------------------------
// The loop
// ---------------------------------------------------------------------------

run :: proc(args: Args) -> int {
	bot.link = link_make(args.nick, args.port)
	bot.cache = cache_make()
	bot.lim = limiter_make()
	bot.queue = make([dynamic]Action)
	bot.joined = make(map[string]bool)

	// Say up front what this is. The model is half a gigabyte; the one thing
	// worse than a wrong answer is a wrong answer that looked authoritative.
	st := ollama_probe(args.model, context.temp_allocator)
	if st.up {
		note("ollama %s is up; model %s %s", st.version, args.model, st.has ? "is present" : "is NOT pulled")
	} else {
		note("ollama is not reachable (%s) — I will say so in the channel", st.err)
		note("start it with: %s", OLLAMA_START_HINT)
	}
	note("joining 127.0.0.1:%d as %q, answering to @%s", args.port, args.nick, args.nick)

	for {
		free_all(context.temp_allocator)

		if !bot.link.online {
			if now_s() < bot.link.retry_at {
				time.sleep(50 * time.Millisecond)
				continue
			}
			if !link_dial(&bot.link) {
				bot.link.retry_at = now_s() + bot.link.retry_in
				bot.link.retry_in = min(bot.link.retry_in * 2, 5.0)
				continue
			}
			bot.link.retry_in = 0.4
			bot.seeded = false
			note("connected")
		}

		for f in link_poll(&bot.link) {
			apply(&bot, f)
		}

		if bot.job.live {
			job_step(&bot)
		} else if len(bot.queue) > 0 {
			a := bot.queue[0]
			ordered_remove(&bot.queue, 0)
			job_begin(&bot, a)
		} else {
			time.sleep(25 * time.Millisecond)
		}

		if args.max_replies > 0 && bot.replies >= args.max_replies && !bot.job.live {
			note("%d replies done, exiting", bot.replies)
			link_close(&bot.link)
			return 0
		}
	}
}

// ---------------------------------------------------------------------------
// Incoming frames
// ---------------------------------------------------------------------------

apply :: proc(b: ^Bot, o: json.Object) {
	switch w.ostr(o, "t") {
	case "welcome":
		note("hello accepted, proto %d", w.oint(o, "proto"))
		for ch in b.args.channels {
			link_join(&b.link, ch)
			b.joined[strings.clone(ch)] = true
		}

	case "channels":
		// The bot can see every `channel` without joining — the server
		// broadcasts them to all connections — so this is only about seeding
		// the context window with what was said before it arrived.
		if b.seeded {
			return
		}
		b.seeded = true
		n := 0
		for cv in w.oarr(o, "list") {
			co, ok := w.as_obj(cv)
			if !ok || w.ostr(co, "kind") != "channel" {
				continue
			}
			if n >= 8 {
				break
			}
			link_history(&b.link, w.ostr(co, "name"), 30)
			n += 1
		}
		note("seeding context from %d channel(s)", n)

	case "history":
		for mv in w.oarr(o, "msgs") {
			if mo, ok := w.as_obj(mv); ok {
				cache_put(&b.cache, w.msg_from(mo, context.allocator))
			}
		}

	case "thread":
		if ro, ok := w.as_obj(o["root"] or_else nil); ok {
			cache_put(&b.cache, w.msg_from(ro, context.allocator))
		}
		for mv in w.oarr(o, "msgs") {
			if mo, ok := w.as_obj(mv); ok {
				cache_put(&b.cache, w.msg_from(mo, context.allocator))
			}
		}

	case "message":
		mo, ok := w.as_obj(o["msg"] or_else nil)
		if !ok {
			return
		}
		m := w.msg_from(mo, context.allocator)
		cache_put(&b.cache, m)
		consider(b, m)

	case "edit":
		cache_edit(&b.cache, w.oint(o, "id"), w.ostr(o, "text"), w.oint(o, "edited"))

	case "delete":
		cache_delete(&b.cache, w.oint(o, "id"))

	case "error":
		// Never the message text: just the code, which is the part that says
		// what this client got wrong.
		note("server error %q: %s", w.ostr(o, "code"), w.ostr(o, "msg"))

	case:
	}
}

// consider is the only entry from "a message arrived" to "the bot does
// something". It delegates the decision to `decide`, which cannot return
// anything but `.Ignore` for a message the bot wrote.
consider :: proc(b: ^Bot, m: w.Msg) {
	a := decide(b.args.nick, m, context.temp_allocator)
	if a.act == .Ignore {
		return
	}

	// `stop` is a control, not a reply: it is not queued, not rate-limited,
	// and it never starts a generation.
	if a.act == .Stop {
		if b.job.live {
			gen_stop(&b.job.gen)
			note("stop asked for message %d", b.job.msg_id)
		} else {
			post_one(b, a, fmt.tprintf("Nothing to stop — I am not writing anything.%s", footer(b.args.model)))
		}
		return
	}

	ok, why := limiter_allow(b.lim, now_ms())
	if !ok {
		b.dropped += 1
		note("ignoring mention in message %d: %s (%d dropped)", m.id, why, b.dropped)
		return
	}
	if len(b.queue) >= QUEUE_MAX {
		b.dropped += 1
		note("ignoring mention in message %d: %d already queued", m.id, QUEUE_MAX)
		return
	}
	// Clone out of the frame's temp allocator: this action outlives the pass.
	q := a
	q.ch = strings.clone(a.ch)
	q.asker = strings.clone(a.asker)
	q.prompt = strings.clone(a.prompt)
	append(&b.queue, q)
	limiter_note(&b.lim, now_ms())
	note("queued %v for message %d in #%s (thread %d)", a.act, m.id, a.ch, a.thread)
}

// ---------------------------------------------------------------------------
// Answering
// ---------------------------------------------------------------------------

// post_one is the single-broadcast reply: help, a complaint, an error. One
// `post`, no edits, nothing streamed.
post_one :: proc(b: ^Bot, a: Action, text: string) {
	tag := link_post(&b.link, a.ch, text, a.thread)
	if tag != "" {
		delete(tag)
	}
	b.replies += 1
	note("replied in #%s with one message (1 broadcast)", a.ch)
}

job_begin :: proc(b: ^Bot, a: Action) {
	switch a.act {
	case .Ignore, .Stop:
		return
	case .Help:
		post_one(b, a, help_text(b.args.nick, b.args.model))
		return
	case .Bad_Id:
		post_one(
			b,
			a,
			fmt.tprintf(
				"Give me a message id to explain, like `@%s explain 41`. The id is the number on the message.%s",
				b.args.nick,
				footer(b.args.model),
			),
		)
		return
	case .Ask, .Summarise, .Explain:
	}

	// A thread reply never appears in the channel timeline, so the thread's
	// own messages may be entirely absent from the window. Ask for them.
	if a.thread != 0 {
		rq := link_thread(&b.link, a.thread)
		_ = drain_until(b, "thread", rq, 800)
	}

	msgs := a.thread != 0 ? cache_thread(&b.cache, a.thread) : cache_channel(&b.cache, a.ch)
	turns := context_turns(msgs, b.args.nick)

	// The instruction turn goes last, after the conversation, so a 0.6B model
	// has the task in front of it rather than six messages back.
	all := make([dynamic]Turn, context.temp_allocator)
	append(&all, ..turns)
	switch a.act {
	case .Ask:
		append(&all, Turn{role = .User, text = fmt.tprintf("%s is asking you directly: %s", a.asker, a.prompt)})
	case .Summarise:
		append(&all, Turn{role = .User, text = SUMMARISE_PROMPT})
	case .Explain:
		tgt, found := cache_find(&b.cache, a.target)
		if !found || tgt.deleted {
			post_one(
				b,
				a,
				fmt.tprintf(
					"I cannot see message %d — it is outside the %d messages I keep in view, or it was deleted.%s",
					a.target,
					CACHE_MAX,
					footer(b.args.model),
				),
			)
			return
		}
		if !w.dm_has(tgt.ch, b.args.nick) && tgt.ch != a.ch {
			// Explaining a message from another channel into this one would
			// move text across an audience boundary. Refuse.
			post_one(
				b,
				a,
				fmt.tprintf(
					"Message %d is not in this channel, so I will not quote it here.%s",
					a.target,
					footer(b.args.model),
				),
			)
			return
		}
		append(&all, Turn{role = .User, text = explain_prompt(tgt)})
	case .Ignore, .Stop, .Help, .Bad_Id:
	}

	sys := system_prompt(b.args.nick, b.args.model, a.ch, a.thread != 0)
	body := chat_body(b.args.model, sys, all[:], NUM_PREDICT, 0.6, context.allocator)
	defer delete(body)

	ctx_bytes := context_bytes(all[:])
	note(
		"answering message %d in #%s: %d context turns, %d bytes (caps %d/%d)",
		a.src,
		a.ch,
		len(all),
		ctx_bytes,
		CTX_MAX_MSGS,
		CTX_MAX_BYTES,
	)

	// Post the placeholder first and learn its id from the broadcast's echoed
	// `tag`: there is no direct reply to `post`, and the broadcast is the
	// authority on what the server accepted.
	placeholder := render_reply("", b.args.model, false, false)
	tag := link_post(&b.link, a.ch, placeholder, a.thread)
	if tag == "" {
		note("could not post: the link went away")
		return
	}
	defer delete(tag)
	id, got := drain_for_tag(b, tag, 2500)
	if !got {
		note("the server never echoed my post; giving up on this one")
		return
	}

	j := &b.job
	j^ = Job {
		live    = true,
		act     = a,
		msg_id  = id,
		bcasts  = 1, // the placeholder
		started = now_ms(),
		flow    = Flow{last_ms = now_ms(), last_len = 0},
		published = strings.clone(placeholder),
	}

	if err := gen_start(&j.gen, body); err != "" {
		// ollama is not there. Say so, with the command, in the channel.
		text := strings.contains(err, "cannot reach") \
			? no_ollama_text(b.args.model) \
			: fmt.tprintf("I could not reach the model: %s%s", err, footer(b.args.model))
		publish(b, text)
		job_end(b)
		return
	}
	link_typing(&b.link, a.ch, true)
}

// job_step is one pass of a live generation: one bounded ollama read, one
// drain of the chat socket, and an edit if the coalescing policy says so.
job_step :: proc(b: ^Bot) {
	j := &b.job
	_ = gen_pump(&j.gen)

	// Service the chat socket between ollama reads. This is what makes `stop`
	// land inside a fifth of a second.
	for f in link_poll(&b.link) {
		apply(b, f)
	}

	text := gen_text(&j.gen)
	done := j.gen.finished
	if !coalesce_due(COALESCE, j.flow, now_ms(), text, done) {
		return
	}

	out := ""
	switch {
	case done && j.gen.err != "" && strings.builder_len(j.gen.text) == 0:
		// Nothing was written at all, so the message says what went wrong
		// instead of sitting there as an empty bubble.
		out = strings.contains(j.gen.err, "cannot reach") \
			? no_ollama_text(b.args.model) \
			: fmt.tprintf("I could not finish: %s%s", j.gen.err, footer(b.args.model))
	case done && j.gen.err != "":
		// A partial answer plus a reason. Silently keeping the fragment would
		// make a truncated reply look like a complete one.
		out = render_reply(
			fmt.tprintf("%s\n\n*(cut short: %s)*", text, j.gen.err),
			b.args.model,
			true,
			j.gen.stopped,
		)
	case:
		out = render_reply(text, b.args.model, done, j.gen.stopped)
	}

	if out != j.published {
		publish(b, out)
		j.flow = Flow {
			last_ms  = now_ms(),
			last_len = len(text),
			edits    = j.flow.edits + 1,
		}
	}
	if done {
		job_end(b)
	}
}

// publish sends the edit and counts it. Every broadcast this reply costs the
// workspace goes through here or through the one `post` in `job_begin`.
publish :: proc(b: ^Bot, text: string) {
	j := &b.job
	if j.msg_id == 0 {
		return
	}
	if !link_edit(&b.link, j.msg_id, text) {
		return
	}
	j.bcasts += 1
	delete(j.published)
	j.published = strings.clone(text)
}

job_end :: proc(b: ^Bot) {
	j := &b.job
	link_typing(&b.link, j.act.ch, false)
	secs := f64(now_ms() - j.started) / 1000.0
	note(
		"message %d finished: %d tokens in %.1fs, %d broadcasts (1 post + %d edits), %.2f broadcasts/s%s",
		j.msg_id,
		j.gen.chunks,
		secs,
		j.bcasts,
		j.bcasts - 1,
		secs > 0 ? f64(j.bcasts) / secs : 0,
		j.gen.stopped ? " [stopped]" : "",
	)
	// Safe on a Gen whose dial never succeeded: `gen_start` builds the buffers
	// before it opens the socket, and `gen_destroy` only closes what is open.
	gen_destroy(&j.gen)
	delete(j.published)
	j.live = false
	j.msg_id = 0
	b.replies += 1
}

// ---------------------------------------------------------------------------
// Bounded waits
// ---------------------------------------------------------------------------

// drain_until polls the chat socket until a frame of type `t` (with request
// id `rq`, when non-zero) has been applied, or the budget runs out.
drain_until :: proc(b: ^Bot, t: string, rq: i64, ms: int) -> bool {
	spent := 0
	for spent < ms {
		hit := false
		for f in link_poll(&b.link) {
			apply(b, f)
			if w.ostr(f, "t") == t && (rq == 0 || w.oint(f, "rq") == rq) {
				hit = true
			}
		}
		if hit {
			return true
		}
		if !b.link.online {
			return false
		}
		time.sleep(15 * time.Millisecond)
		spent += 15
	}
	return false
}

// drain_for_tag waits for the broadcast of the bot's own post, identified by
// the tag the server echoes back, and returns the id the server assigned.
drain_for_tag :: proc(b: ^Bot, tag: string, ms: int) -> (id: i64, ok: bool) {
	spent := 0
	for spent < ms {
		for f in link_poll(&b.link) {
			apply(b, f)
			if w.ostr(f, "t") != "message" || w.ostr(f, "tag") != tag {
				continue
			}
			if mo, good := w.as_obj(f["msg"] or_else nil); good {
				return w.oint(mo, "id"), true
			}
		}
		if !b.link.online {
			return 0, false
		}
		time.sleep(10 * time.Millisecond)
		spent += 10
	}
	return 0, false
}

// ---------------------------------------------------------------------------
// Used by --e2e
// ---------------------------------------------------------------------------

wait_for_port :: proc(port: int, ms: int) -> bool {
	spent := 0
	for spent < ms {
		sock, err := net.dial_tcp(net.Endpoint{address = net.IP4_Loopback, port = port})
		if err == nil {
			net.close(sock)
			return true
		}
		time.sleep(25 * time.Millisecond)
		spent += 25
	}
	return false
}
