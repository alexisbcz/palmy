# palmy-chatbot

The local model as a chat participant. Mention it in a channel and it answers,
streaming the reply into a message it keeps editing as the tokens arrive.

```sh
odin build apps/chatbot -o:speed -out:apps/chatbot/chatbot.bin

apps/chatbot/chatbot.bin --selftest          # 226 assertions, no server, no model
apps/chatbot/chatbot.bin --e2e               # server + bot + client, needs ollama
apps/chatbot/chatbot.bin                     # join 127.0.0.1:8787 as @qwen3-bot
```

No collections are needed: this app imports `apps/chat/wire` and nothing else.
It has no window, so it does not depend on palmy or shadcn at all.

## It is a client, not part of the server

The bot is a separate process holding two sockets: the chat server over TCP,
and ollama at `127.0.0.1:11434` over HTTP/1.1.

That is the one architectural decision everything else follows from. The chat
server holds **one mutex over all shared state and broadcasts inside the
critical section**, which is what makes the order every client sees the order
the server committed. A generation takes seconds. Model inference anywhere near
that lock would stall every client in the workspace for the length of a reply.
As an ordinary client the bot has no way to reach that lock, so the property is
structural rather than a rule somebody has to remember.

There are no threads here either. One loop alternates between the two sockets:
the chat socket is non-blocking and drained every pass, and ollama's has a
200 ms receive timeout, so a `@bot stop` that lands between two reads takes
effect within a fifth of a second. Nothing in this program needs a mutex.

## Talking to it

| | |
| --- | --- |
| `@qwen3-bot <question>` | answer, with the recent channel as context |
| `@qwen3-bot summarise` | summarise the recent conversation |
| `@qwen3-bot explain 41` | explain or expand on one message, by id |
| `@qwen3-bot stop` | abandon the reply being written |
| `@qwen3-bot help` | the list above |

`@bot` and `@ai` are accepted as aliases. In a DM every message is addressed by
construction — the channel name contains both nicknames — so the sigil is
optional there. A mention inside a thread is answered inside that thread, and
the context is then the thread's messages rather than the channel's.

`explain 41` is the command; `explain how a rasterizer works` is an ordinary
question that happens to start with the same word. Only an id makes it the
command.

## Streaming, and how often it broadcasts

ollama emits one NDJSON object per token. An `edit` per token would be a
broadcast per token to every connected client — several hundred frames, all
through the server's one mutex, for one answer. That is a denial of service you
wrote yourself, and it is the obvious thing to build.

So the policy, in `coalesce_due`:

* never two edits closer than **700 ms**, and never for fewer than **24** new
  characters;
* **unless** a sentence just ended and 350 ms have passed, in which case flush
  early — a paragraph appearing whole reads far better than one appearing
  mid-clause.

The cost is latency: a token can sit unpublished for up to 700 ms, so the reply
trails the model by about three quarters of a second. For a reply that takes
five to thirty seconds that is invisible.

Measured, over a real server with a real second client watching:

| reply | broadcasts | an edit per token would have been |
| --- | --- | --- |
| 167 bytes | 3 (1 post + 2 edits) | ~40 |
| 1134 bytes | 8 (1 post + 7 edits) | ~283 |

Two `typing` frames bracket each reply, which are not echoed to the sender.

## Context

Both caps apply, whichever trips first:

* **20 messages** back (`CTX_MAX_MSGS`)
* **6000 bytes** of conversation (`CTX_MAX_BYTES`)
* one message is clipped at **1200 bytes** (`CTX_MAX_LINE`), so a single wall of
  pasted text cannot eat the window on its own

The walk is backwards, so when the byte cap trips it is the *oldest* context
that is dropped. The bot's own messages become `assistant` turns with their
attribution footer stripped; everyone else becomes a `user` turn prefixed with
their nickname. A thread reply uses the thread, not the channel.

Replies are capped at 512 tokens and clipped to fit the server's 4000-byte
message limit with the footer intact — an edit the server refuses would leave a
half-written answer in the channel forever.

## Being honest about what it is

The model is `qwen3:0.6b`: half a gigabyte, quick, and frequently wrong. The
nickname says it is a model, and every state of every reply carries the model
name — the placeholder, each streaming update, and the footer on the finished
message. If ollama is not running the bot says so in the channel with the exact
command to start it, rather than failing silently.

## What it will not do

* **ollama is loopback only.** `127.0.0.1:11434` as a literal, with no host
  parameter and no name resolution — not even `localhost`, because resolving a
  name is the step that can be made to point elsewhere. `is_loopback` is
  asserted on every dial.
* **It never touches `ollama.service`.** ollama is deliberately a user process
  on this machine; the unit is disabled and stays that way.
* **It does not keep what it reads.** Nothing here writes a message to a file,
  prints one to a log, or sends one anywhere but the local ollama. The progress
  output takes ids, counts and nicknames. There is no state directory because
  there is no state: the bot holds a 400-message window in memory and that is
  all.
* **It cannot loop.** `decide`'s first statement returns `.Ignore` for a message
  the bot wrote, before the text is looked at, and nothing but a mention (or a
  DM) can produce an action at all. On top of that: one generation in flight at
  a time, at most one reply every 1.2 s, and at most 12 a minute. The self-test
  fires ten thousand mentions in ten seconds and asserts that at most twelve
  replies come out.

## Verifying

`--selftest` needs neither a chat server nor a model. It replays a canned
ollama transcript — chunked HTTP carrying NDJSON, with objects deliberately cut
across chunk boundaries and inside a JSON string — at *every* split size from
one byte to the whole response, and asserts the assembled reply is identical
each time. That is the bug every streaming client has once: a `recv` landing
between the `\r` and the `\n` of a chunk terminator. The rest covers mention
parsing, the decision table, the self-reply guard, the context caps, the
coalescing policy counted against a per-token baseline, the rate limiter, the
loopback gate, and the shape of a reply on the wire.

`--e2e` starts a real chat server on a scratch port and store, starts this
binary again as a separate bot process, connects an ordinary client, and
measures the broadcasts a reply costs from the receiving end.

## The demo

```sh
bash apps/chatbot/record.sh apps/chatbot/demo.mp4 apps/chatbot/demo.txt 1280 800
```

One server, one bot process, one client, on a private headless compositor.
`CHAT_CLIENT` and `CHAT_SERVER` point at the chat binaries, which live in
another directory and may be built anywhere.

The conversation is posted over the real protocol rather than typed into the
window, and the reason is a toolkit limitation worth writing down: against a
palmy window only the **first** `wtype` invocation ever lands. Three
invocations 1.5 s apart put `A` in the composer and then nothing — on the
working tree and on the last commit alike — so a `type` step followed by
`key Return` silently does nothing and a demo built out of them records an
empty conversation.
