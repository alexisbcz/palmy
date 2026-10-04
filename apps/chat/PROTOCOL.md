# palmy-chat protocol v1

A small, length-prefixed JSON protocol over TCP. It is deliberately readable on
the wire — `nc 127.0.0.1 8787 | xxd` tells you what went wrong — and the whole
of it is implemented in `wire/wire.odin` (framing and records),
`server/main.odin` (the authority) and `net.odin` (the client half).

The server **binds 127.0.0.1 only**. There is no LAN mode and no flag to add
one; a socket on this machine talks to clients on this machine.

`PROTO_VERSION` is still 1. Threads, read cursors and attachments were added
without breaking anything: every new field on a message object is omitted when
it is zero, every new request is a new `t`, and a client that has never heard
of them behaves exactly as it did. The one behavioural change is that
`history` no longer returns thread replies — which only matters once something
creates one.

## Framing

```
+--------+--------+--------+--------+----------------------------+
|  len[31:24] ...  big-endian u32   |  len bytes of UTF-8 JSON   |
+--------+--------+--------+--------+----------------------------+
```

One frame carries exactly one JSON object. `len` may not exceed 1 MiB
(`wire.MAX_FRAME`); a peer that claims more is corrupt and the connection is
closed. A frame's header and body are always written in a single `send`, so
concurrent writers to one socket can never splice a header onto another body.

Every object has a string field `t`, the message type. A client request may
carry `"rq": <int>`; the direct reply to that request echoes it back as `"rq"`,
which is how the headless self-test correlates without ordering assumptions.
Broadcasts carry no `rq`.

## Records

A **message** object, used in `message`, `history`, `results`, `thread` and
the on-disk log:

```json
{
  "id": 41,              // server-assigned, strictly increasing across all channels
  "ch": "general",       // channel name
  "nick": "alexis",
  "text": "ship **it**", // raw markdown; rendering is the client's business
  "ts": 1759533123,      // unix seconds, server clock
  "edited": 1759533200,  // omitted when never edited
  "deleted": true,       // omitted when false; text is cleared when set
  "reply_to": 38,        // omitted when not a reply: a quoted stub in the channel
  "thread": 36,          // omitted unless this is a reply *inside* a thread
  "replies": 4,          // omitted when 0: how many replies hang off this root
  "last_reply": 1759533400, // present with `replies`
  "file": {              // omitted when there is no attachment
    "id": 44, "name": "parity.txt", "mime": "text/plain", "size": 2048
  },
  "reacts": [ { "key": "heart", "nicks": ["sam"] } ]   // omitted when empty
}
```

A **channel** object: `{"name":"general","kind":"channel","topic":"..."}`.
`kind` is `channel` or `dm`. A DM channel's name is the two participants'
nicknames sorted and joined with `+` — `alexis+sam` — so both ends derive the
same name without being told it, and the server refuses any DM whose name does
not contain the asking nickname.

## Threads

A thread is a place, not a decoration. Its identity is the id of its **root**
message; a reply inside it carries `thread: <root id>` and the root carries
`replies` and `last_reply`.

Three rules make it coherent:

1. **A thread reply is not in the channel timeline.** `history` never returns
   a message with `thread` set. The only ways to reach one are the `thread`
   request and `search`.
2. **Threads are exactly one level deep.** `post` with `thread` pointing at a
   reply is normalised to that reply's own root, so "reply to a reply" lands
   in the one thread instead of nesting. A root in a different channel from
   `ch` is refused with `no_thread` — a thread reply must never reach an
   audience its root cannot.
3. **The count is derived, never logged.** At startup the server rebuilds
   every root's `replies` and `last_reply` by walking the replayed messages,
   so a restarted server agrees with a live one by construction and there is
   one fewer thing the log can be inconsistent about.

`reply_to` is unchanged and still means a quoted stub in the channel. The two
are different acts and both exist: a quote-reply is a message everyone in the
channel reads, a thread reply is not.

## Read cursors and unread

A **read cursor** is the highest message id a *nickname* has told the server it
has read, in one channel. It is keyed on the nickname rather than the
connection, it is written to the log, and it is replayed at startup — so it
follows the user between clients and across restarts.

**Unread is never stored.** Every number the server reports is derived from the
cursor by walking the log: a message counts when its id is above the cursor, it
is not deleted, and it is not the reader's own. So a count and its cursor
cannot drift apart, because there is only one of them and the other is
computed.

Three numbers come out of that walk:

| field | meaning |
| --- | --- |
| `unread` | new messages in the channel timeline |
| `threads` | new replies inside threads, which are **not** timeline rows |
| `mention` | any unread timeline message whose text contains the nickname |

Thread replies are counted apart from `unread` deliberately. The badge sits
next to a channel in a sidebar, and inflating it for a reply that is not a row
in that channel would promise a message the user cannot find.

Two invariants:

- **A cursor only moves forward**, and it is **clamped to a message that
  exists**. A stale client re-announcing an old position — an old tab, a
  replayed frame — must not resurrect messages the user has read somewhere
  else; and because the cursor is forward-only *and* persisted, one frame
  claiming `id: 2^63-1` would otherwise mark the channel read for that
  nickname for ever, including every message not yet written, with no way
  back.
- **A nickname the server has never seen is parked at the newest message** of
  every channel it can see, once, and that seeding is logged. Without it a
  brand-new client would open onto the entire history marked unread, which is
  not what "you have just arrived" means. Because the seeding is logged, a
  reconnect is never mistaken for a first arrival.

This replaces what v1 did, which was to derive unread from the highest id the
client had displayed *while connected*. That reset to zero on every reconnect,
which is the one thing a chat client must not get wrong.

## Attachments

A file travels base64'd inside one ordinary JSON frame, is stored under a path
the **server builds**, and comes back only by id.

- The cap is `wire.MAX_ATTACH`, 512 KiB of bytes — 699 KiB of base64, which
  still leaves room for the envelope inside the 1 MiB frame limit.
- The stored name is `<message id>-<safe_filename(name)>` inside
  `<dir>/files/`. `safe_filename` keeps only `[A-Za-z0-9._-]`, never emits a
  leading `.`, and truncates to 60 bytes, so no separator, no `..` and no
  hidden file can come out of it. The server then checks the built path still
  begins with its own store directory before writing. A client never names a
  path and never sees one.
- `fetch` takes a **message** id, re-derives the path from the stored record,
  and applies the same `can_see` check as the message itself. The only files
  reachable are ones this server wrote.
- The bytes are not in `history`; only the metadata is. A 50-message page of a
  channel full of images is still a few kilobytes.
- `mime` is bounded at 127 printable bytes. It is the one string a client
  sends that nothing else caps, and it is persisted and re-emitted inside
  every `history` frame — so an unbounded one would eventually push a
  channel's history past `MAX_FRAME`, and a frame that cannot be sent gets the
  connection reaped. Permanently, since the log replays.
- The decode and the disk write happen **before** the lock is taken. `handle`
  base64-decodes the frame and writes the bytes to a hidden staging file in
  the store; the critical section only `rename`s it into place, which is a
  metadata operation. Without that, one 512 KiB upload would hold the single
  mutex across a decode and a blocking write while every other client's
  broadcast queued behind it. A staging file that is never renamed — a
  rejected upload, or a server killed mid-transfer — is removed on the spot or
  swept at the next boot.

**Presence** is one of `online`, `away`, `offline`. It is a property of a
nickname, not of a connection: the last connection for a nickname going away is
what makes it `offline`.

A **reaction key** is one of `thumbsup`, `heart`, `party`, `rocket`, `fire`,
`grin`. The set is closed, and intentionally not emoji — see the note at the
bottom.

## Client → server

| `t` | fields | effect / reply |
| --- | --- | --- |
| `hello` | `nick`, `presence?` | Required first message. Reply: `welcome`, then `channels`, then `users`, then `reads`. Rejected with `error` (`bad_nick`, `already_hello`) otherwise. |
| `channels` | — | Reply `channels`. |
| `join` | `ch`, `kind?` (`channel`\|`dm`), `topic?` | Joins, creating the channel if it does not exist. Reply `joined`; broadcast `channels` when a channel was created. |
| `leave` | `ch` | Reply `left`. |
| `post` | `ch`, `text`, `reply_to?`, `thread?`, `tag?` | Appends a message. Broadcast `message` to everyone who can see `ch`. With `thread`, the message is a reply inside that thread and a `replies` broadcast follows it. `tag` is echoed back on the broadcast so the author can match its own optimistic row. |
| `history` | `ch`, `before?`, `limit?` | Reply `history` with up to `limit` (default 50, max 200) messages whose id is `< before`, oldest first, plus `more`. Paging walks backwards: pass the lowest id you have as the next `before`. |
| `typing` | `ch`, `on` | Broadcast `typing` to everyone else in `ch`. Never persisted. |
| `edit` | `id`, `text` | Author only. Broadcast `edit`. `error` `not_yours` otherwise. |
| `delete` | `id` | Author only. Tombstones the message (text cleared, `deleted` set). Broadcast `delete`. |
| `react` | `id`, `key`, `on` | Adds or removes the caller's reaction. Broadcast `react`. |
| `presence` | `state` | Sets this nickname's presence. Broadcast `presence`. |
| `search` | `q`, `limit?` | Case-insensitive substring search over every message the caller can see, newest first, thread replies included. Reply `results`. |
| `thread` | `id`, `limit?` | `id` may be a root or any reply in it. Reply `thread` with the root and the newest `limit` replies (default and max 120), oldest first, plus the real `replies` count and `more`. `error` `no_message` / `no_channel`. |
| `read` | `ch`, `id` | Moves this nickname's read cursor in `ch` forward to `id`. Broadcast `read` to every connection of that nickname, including this one. |
| `reads` | — | Reply `reads`: every visible channel's cursor and the counts derived from it. Also sent unasked, right after `hello`. |
| `attach` | `ch`, `name`, `mime?`, `text?`, `thread?`, `data` (base64) | Stores the file and posts a message carrying its metadata. `error` `bad_file`, `too_big`, `store_failed`. |
| `fetch` | `id` | A message id. Reply `file` with the bytes base64'd. `error` `no_file`. |
| `ping` | — | Reply `pong`. |

## Server → client

| `t` | fields |
| --- | --- |
| `welcome` | `proto`, `nick`, `server` |
| `channels` | `list`: array of channel objects |
| `users` | `list`: `[{"nick":…,"state":…}]` |
| `joined` / `left` | `ch` |
| `message` | `msg`: a message object, `tag?` |
| `history` | `ch`, `msgs`: array (oldest first), `more`: bool |
| `edit` | `id`, `ch`, `text`, `edited` |
| `delete` | `id`, `ch` |
| `react` | `id`, `ch`, `key`, `nick`, `on` |
| `typing` | `ch`, `nick`, `on` |
| `presence` | `nick`, `state` |
| `results` | `q`, `msgs`: array (newest first) |
| `thread` | `id` (root), `ch`, `root`: a message object, `msgs`: the replies (oldest first), `replies`: the real total, `more`: bool |
| `replies` | `id` (root), `ch`, `n`: the new count, `last_reply`, `nick`: who replied |
| `reads` | `list`: `[{"ch":…,"id":…,"unread":…,"threads":…,"mention":…}]` |
| `read` | `ch`, `id`, `unread`, `threads`, `mention` |
| `file` | `id`, `name`, `mime`, `size`, `data` (base64) |
| `error` | `code`, `msg` |
| `pong` | — |

`message`, `edit`, `delete`, `react`, `replies` and `typing` are delivered to every
connection that can see the channel: for a `channel` that is everyone, for a
`dm` only the two participants. The author's own connection is included, so a
client never has to guess what the server accepted — the row it draws is the
row the server broadcast. `typing` is the one exception: it is not echoed to
its sender.

`read` is the exception in the other direction: it goes to every connection of
**one nickname** rather than to a channel, because a read cursor is a property
of the person. A second client of the same user stops showing a badge for
something read on the first.

## Ordering

Every mutation takes the server's single mutex, assigns the next id, writes the
log and broadcasts, all inside one critical section. So the order any two
clients observe is the same order, and it is the order ids were assigned. There
is no sequence number on the wire because the message id already is one.

Threads do not weaken that, and the place it could have gone wrong is the
reply count. A thread reply's `message` broadcast and the `replies` broadcast
that updates its root happen in that order, inside the **same** critical
section as the id assignment — `locked_commit` is the only place a message is
created, and it does all four things before unlocking. Two consequences worth
stating:

- A thread reply's id comes from the one global counter, so replies interleave
  with channel messages in a single total order. There is no separate
  per-thread sequence to reconcile.
- No client can ever observe a reply count before the reply it counts. A count
  of 4 means the four messages are already on their way to you, ahead of it,
  on the same socket.

## Verifying the locking

`bash apps/chat/verify-locks.sh` reads `server/main.odin` and checks the
discipline the ordering guarantee rests on, from the source:

1. exactly four procedures take `srv.mu` — `boot`, `main` (the accept loop),
   `handle` and `drop_conn`;
2. each of them takes it exactly once, in one place;
3. no `locked_*` procedure can reach a lock, **transitively** — a `locked_*`
   that calls something that calls `handle` deadlocks just as surely as one
   that calls `sync.lock` itself — and the lock is recognised under every name
   `core:sync` gives it, `mutex_lock` and `guard` included, because a check
   that only knows `sync.lock` would pass the exact edit it exists to catch;
4. the four call only `locked_*` across the boundary, apart from a short
   explicit list of state-free helpers, so adding another is a deliberate act;
5. `locked_send` is the only thing that writes a frame, which is what makes a
   dead peer get reaped rather than retried.

It reads every `.odin` file in `server/`, and it strips comments and string
literals properly first — a `//` inside a literal or a `}` inside a block
comment used to truncate a procedure and silently skip everything after it.

It exits non-zero when any of that stops being true. It is checked in because
reviewing for it by eye does not scale: the failure mode is a deadlock on the
first message, and there are forty-one `locked_*` procedures now.

What it does **not** prove, since a green run should not be read for more than
it says: it follows direct, named calls only, so a procedure passed as a value
(`thread.create_and_start_with_poly_data(c, conn_thread, …)`) is not an edge in
its graph; check 4 looks at direct callees rather than the transitive closure,
against a hand-maintained list of state-free helpers; and it cannot see *work*
done under the lock, so a long disk write inside a `locked_*` procedure is a
latency bug it will call clean. That last one is why the attachment path is
staged outside the lock by hand rather than left for the script to notice.

## Persistence

`~/.local/share/palmy-chat/log.jsonl` — one JSON event per line, appended and
written straight through, replayed in order at startup:

```json
{"e":"chan","name":"general","kind":"channel","topic":"…"}
{"e":"msg","id":1,"ch":"general","nick":"alexis","text":"hi","ts":…}
{"e":"edit","id":1,"text":"hi there","at":…}
{"e":"del","id":1}
{"e":"react","id":1,"key":"heart","nick":"sam","on":true}
{"e":"read","nick":"alexis","ch":"general","id":41}
```

A `msg` event carries `thread` and `file` like any other message object. Reply
counts are **not** logged: `locked_recount_threads` rebuilds them after replay.
Attachment bytes are not in the log either — they are already files under
`<dir>/files/`, and the `msg` event holds only the metadata.

Replay is the same code path that applies a live event, so a restarted server
is in exactly the state it was in. `--dir` points the log somewhere else, which
is what the self-test uses.

## Reproducing

```sh
odin build apps/chat        -collection:palmy=.../palmy -collection:shadcn=.../shadcn -collection:kit=.../apps/kit -o:speed -out:apps/chat/chat.bin
odin build apps/chat/server -collection:palmy=.../palmy -collection:shadcn=.../shadcn -collection:kit=.../apps/kit -o:speed -out:apps/chat/server/chat-server.bin

apps/chat/chat.bin --selftest          # headless protocol test, 164 assertions
bash apps/chat/verify-locks.sh         # static check of the locking discipline
apps/chat/server/chat-server.bin       # 127.0.0.1:8787
apps/chat/chat.bin --nick alexis       # a client

# One-shot clients, which is how the demo seeds a conversation and how a
# script talks to the server without a window:
apps/chat/chat.bin --nick sam --post general 'hello'
apps/chat/chat.bin --nick sam --post general 'in the thread' --thread 41
apps/chat/chat.bin --nick sam --attach general ./parity.txt

# Two real clients, side by side, on a private headless compositor:
bash apps/chat/record.sh apps/chat/demo.mp4 apps/chat/demo.txt 1920 1080
```

The recorder drives its own invisible sway rather than the user's session, on
its own port and its own scratch store, so it cannot touch the real
`~/.local/share/palmy-chat` and cannot collide with a server you are running.
It has two workarounds in it that are worth knowing about, both documented at
the top of the file: `swaymsg` needs `$SWAYSOCK` set by hand because it will
not find a compositor from `$WAYLAND_DISPLAY`, and a palmy window only accepts
input from the *first* `wtype` process to talk to it — so the whole steps file
is compiled into one `wtype` argv, with the steps that are not keystrokes
triggered through a chord sway holds. The second of those is a toolkit bug and
is reported as one.

## Not in v1

No authentication beyond a self-asserted nickname (it is a loopback socket on a
single-user machine) and no TLS.

Read cursors, first-class threads and attachments **were** on this list. They
are not any more, and the three entries read, verbatim: "no attachments, no
threads-as-first-class (replies are a `reply_to` pointer, which the client
renders as a quoted stub), no server-side unread cursors — unread state is the
client's, derived from the last message id it has displayed." The last of those
was the real defect: it meant every reconnect marked everything read.

Still absent, and deliberately: no read *receipts* (you cannot see where
somebody else's cursor is — a cursor is private to its owner), no per-thread
subscription or mute, no resumable or chunked upload, and no thumbnailing of
image attachments.

## A note on reactions

The UI font (Geist) has no emoji glyphs, and the only emoji font on this
machine is `NotoColorEmoji.ttf`, a CBDT/CBLC colour-bitmap font that palmy's
stb_truetype rasterizer cannot draw — and palmy has no font fallback. A literal
`👍` in a reaction would be a tofu box. So a reaction key is a name, and the
client draws it as a stroked lucide icon at text size. They render, they scale,
and they are legible in both themes.
