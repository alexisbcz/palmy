# palmy-chat protocol v1

A small, length-prefixed JSON protocol over TCP. It is deliberately readable on
the wire — `nc 127.0.0.1 8787 | xxd` tells you what went wrong — and the whole
of it is implemented in `wire/wire.odin` (framing and records),
`server/main.odin` (the authority) and `net.odin` (the client half).

The server **binds 127.0.0.1 only**. There is no LAN mode and no flag to add
one; a socket on this machine talks to clients on this machine.

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

A **message** object, used in `message`, `history`, `results` and the on-disk
log:

```json
{
  "id": 41,              // server-assigned, strictly increasing across all channels
  "ch": "general",       // channel name
  "nick": "alexis",
  "text": "ship **it**", // raw markdown; rendering is the client's business
  "ts": 1759533123,      // unix seconds, server clock
  "edited": 1759533200,  // omitted when never edited
  "deleted": true,       // omitted when false; text is cleared when set
  "reply_to": 38,        // omitted when not a reply
  "reacts": [ { "key": "heart", "nicks": ["sam"] } ]   // omitted when empty
}
```

A **channel** object: `{"name":"general","kind":"channel","topic":"..."}`.
`kind` is `channel` or `dm`. A DM channel's name is the two participants'
nicknames sorted and joined with `+` — `alexis+sam` — so both ends derive the
same name without being told it, and the server refuses any DM whose name does
not contain the asking nickname.

**Presence** is one of `online`, `away`, `offline`. It is a property of a
nickname, not of a connection: the last connection for a nickname going away is
what makes it `offline`.

A **reaction key** is one of `thumbsup`, `heart`, `party`, `rocket`, `fire`,
`grin`. The set is closed, and intentionally not emoji — see the note at the
bottom.

## Client → server

| `t` | fields | effect / reply |
| --- | --- | --- |
| `hello` | `nick`, `presence?` | Required first message. Reply: `welcome`, then `channels`, then `users`. Rejected with `error` (`bad_nick`, `already_hello`) otherwise. |
| `channels` | — | Reply `channels`. |
| `join` | `ch`, `kind?` (`channel`\|`dm`), `topic?` | Joins, creating the channel if it does not exist. Reply `joined`; broadcast `channels` when a channel was created. |
| `leave` | `ch` | Reply `left`. |
| `post` | `ch`, `text`, `reply_to?`, `tag?` | Appends a message. Broadcast `message` to everyone who can see `ch`. `tag` is echoed back on the broadcast so the author can match its own optimistic row. |
| `history` | `ch`, `before?`, `limit?` | Reply `history` with up to `limit` (default 50, max 200) messages whose id is `< before`, oldest first, plus `more`. Paging walks backwards: pass the lowest id you have as the next `before`. |
| `typing` | `ch`, `on` | Broadcast `typing` to everyone else in `ch`. Never persisted. |
| `edit` | `id`, `text` | Author only. Broadcast `edit`. `error` `not_yours` otherwise. |
| `delete` | `id` | Author only. Tombstones the message (text cleared, `deleted` set). Broadcast `delete`. |
| `react` | `id`, `key`, `on` | Adds or removes the caller's reaction. Broadcast `react`. |
| `presence` | `state` | Sets this nickname's presence. Broadcast `presence`. |
| `search` | `q`, `limit?` | Case-insensitive substring search over every message the caller can see, newest first. Reply `results`. |
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
| `error` | `code`, `msg` |
| `pong` | — |

`message`, `edit`, `delete`, `react` and `typing` are delivered to every
connection that can see the channel: for a `channel` that is everyone, for a
`dm` only the two participants. The author's own connection is included, so a
client never has to guess what the server accepted — the row it draws is the
row the server broadcast. `typing` is the one exception: it is not echoed to
its sender.

## Ordering

Every mutation takes the server's single mutex, assigns the next id, writes the
log and broadcasts, all inside one critical section. So the order any two
clients observe is the same order, and it is the order ids were assigned. There
is no sequence number on the wire because the message id already is one.

## Persistence

`~/.local/share/palmy-chat/log.jsonl` — one JSON event per line, appended and
written straight through, replayed in order at startup:

```json
{"e":"chan","name":"general","kind":"channel","topic":"…"}
{"e":"msg","id":1,"ch":"general","nick":"alexis","text":"hi","ts":…}
{"e":"edit","id":1,"text":"hi there","at":…}
{"e":"del","id":1}
{"e":"react","id":1,"key":"heart","nick":"sam","on":true}
```

Replay is the same code path that applies a live event, so a restarted server
is in exactly the state it was in. `--dir` points the log somewhere else, which
is what the self-test uses.

## Reproducing

```sh
odin build apps/chat        -collection:palmy=.../palmy -collection:shadcn=.../shadcn -collection:kit=.../apps/kit -o:speed -out:apps/chat/chat.bin
odin build apps/chat/server -collection:palmy=.../palmy -collection:shadcn=.../shadcn -collection:kit=.../apps/kit -o:speed -out:apps/chat/server/chat-server.bin

apps/chat/chat.bin --selftest          # headless protocol test, 82 assertions
apps/chat/server/chat-server.bin       # 127.0.0.1:8787
apps/chat/chat.bin --nick alexis       # a client
bash apps/chat/record.sh apps/chat/demo.mp4 apps/chat/demo.txt
```

## Not in v1

No authentication beyond a self-asserted nickname (it is a loopback socket on a
single-user machine), no TLS, no attachments, no threads-as-first-class
(replies are a `reply_to` pointer, which the client renders as a quoted stub),
no server-side unread cursors — unread state is the client's, derived from the
last message id it has displayed.

## A note on reactions

The UI font (Geist) has no emoji glyphs, and the only emoji font on this
machine is `NotoColorEmoji.ttf`, a CBDT/CBLC colour-bitmap font that palmy's
stb_truetype rasterizer cannot draw — and palmy has no font fallback. A literal
`👍` in a reaction would be a tofu box. So a reaction key is a name, and the
client draws it as a stroked lucide icon at text size. They render, they scale,
and they are legible in both themes.
