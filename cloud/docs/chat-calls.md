# Chat and calls

Team chat and multi-party calls for Palmy: spaces with public and private
channels, DMs, threads, reactions, attachments, search, read receipts, and
calls of up to sixteen people through our own SFU with end-to-end encrypted
media. It is one account speaking as one identity at a time, and the identity
boundary is enforced by Postgres, not by the client.

This document is the area's design and its honest status. The wire protocols
are specified in `apps/chat/PROTOCOL.md` (chat, v1 and v2) and
`apps/call/PROTOCOL.md` (media, PCP1 and PCP2).

```
  chat window / chat CLI ──TCP, JSON frames──▶ palm-rtc ──libpq, as the identity──▶ Postgres (RLS)
     (apps/chat)              protocol v2      (cloud/rtc)  ◀── LISTEN rtc ──────────   │
          │                                        │  ▲                                  │
          │ call_join → 60 s token                 │  │ sfu_room / sfu_kick             Storage (rtc bucket)
          ▼                                        ▼  │
  call app (apps/call) ──UDP, PCP2, SFrame──▶ palm-sfu (cloud/rtc/sfu)
                                                forwards ciphertext, never holds a key
```

## The pieces

| | where | what |
| --- | --- | --- |
| schema | `cloud/supabase/migrations/20261019700000_rtc_chat.sql` | spaces, members, channels, channel members, invites, messages, reactions, read cursors, presence, calls, participants, recordings; triggers; RLS; the `rtc` bucket |
| wire format | `…/20261019700100_rtc_wire.sql` | the JSON the gateway sends, made by SQL under the caller's RLS |
| isolation test | `cloud/supabase/tests/rtc_rls.sql` | 90 pgTAP assertions |
| gateway | `cloud/rtc/*.odin` → `palm-rtc` | auth, sessions as the identity, fan-out from `pg_notify`, sync, Storage, call admission, the SFU link; `--e2e`: 92 checks |
| media library | `cloud/rtc/pcp/` | PCP2 header and control, SFrame (RFC 9605), key sealing, safety code, dominant speaker, tier policy, join tokens |
| SFU | `cloud/rtc/sfu/` → `palm-sfu` | rooms, forwarding, simulcast tiers, speaker, kicks; `--selftest`: 100 checks |
| chat client | `apps/chat` | the window (`chat --cloud`), the CLI (`chat <verb>`), the v1 loopback mode unchanged |
| call client | `apps/call` | `call --sfu … --join-token …`: grid and speaker layouts, E2EE, simulcast |
| v1 server | `apps/chat/server` | the account-less, loopback, local-first chat; unchanged, still 164/164 |

## Identity and isolation

Every row belongs to an identity (`identity_id`), and every policy goes
through `can_access_identity()`, directly or through a helper that asks it
about a membership row:

- A **space** is owned by one identity. Identities become **members** only by
  accepting an **invite** row addressed to them by handle. There is no insert
  policy on membership at all; `rtc_accept_invite()` is the only door, and it
  grants exactly what the invite names.
- A **public channel** is read by the space's non-guest members, a **private**
  one and a **DM** by their channel members only. A **guest** invited to one
  channel gets that channel and nothing else.
- **Posting is always as one identity**, which must itself be a member — it is
  not enough that the same person's other identity is.
- **Leaving or being removed** deletes the membership rows, and with them every
  private channel and DM in that space, at once.
- Messages carry the author's handle, name and colour as the space saw them,
  so history keeps its names when people leave; `identities` stays private to
  its owner.

The test the contract asks for, in `rtc_rls.sql`: a session scoped to identity
A reads none of B's spaces, channels, messages, reactions, calls or
attachments, and every write fails — **including when A and B are the same
person** (Alice's personal identity is a stranger to her work space until it
accepts an invitation). Invites grant exactly what they say; a revoked invite
cannot be used; leaving and removal end access to messages, channels, DMs,
calls and Storage objects. 90 assertions, passing under `cloud/dev/test.sh`
alongside accounts and mail (208 in all).

The gateway holds a database role that can switch to `authenticated`, as
PostgREST's authenticator does, and is trusted in the same way: RLS protects
against every client and every scope mistake, not against a compromised
gateway. It holds no way to mint account tokens (ES256: public keys only).

## The gateway

**Sessions.** A client says hello with its account token and the identity it
speaks as. Every statement for it then runs in a transaction that has set
`role authenticated` and the token's claims narrowed to that identity, so the
answer to any request is exactly what RLS gives that identity — the reply's
JSON is built by SQL inside that transaction. An unscoped token must name an
identity (never defaulted); a scoped one (the accounts token hook) can only be
its own.

**Ordering.** Each change in a channel takes the channel's next number under
the channel row's lock: gapless, equal to commit order. Broadcasts come only
from the `pg_notify` stream, which Postgres delivers in commit order, so all
clients see the same order — including for writes made by PostgREST, a bot or
another gateway. Thread replies are announced before the count that includes
them, as v1 guaranteed.

**Reconnecting.** Every change carries a `rev`; a client remembers the highest
per channel and on reconnect asks `sync`, getting every message changed since
— new, edited, deleted, reacted, replied — once, in order, in its current
state.

**Search** is Postgres full text over what the identity can read: each word a
prefix match in the language-neutral `simple` configuration (`deplo` finds
"deploy"), ranked, newest first among equals.

**Measured** (`palm-rtc --e2e`, loopback, one gateway, the cloud/dev stack):
post on one connection to delivery on another — insert, commit, notify, fetch,
send — **2.6 ms p50, 3.1 ms p95**, 100 of 100 delivered.

## Calls

**Admission** is the gateway's: `call_join` inserts the call and the
participation as the identity, so Postgres decides; only then is a 60-second
join token minted for exactly that identity and call. The SFU checks the
token's MAC and expiry and nothing else — it has no database, no account keys
and no media keys.

**Forwarding.** `palm-sfu` is an Odin SFU on one UDP socket: every
participant's audio and video to every other, never back. Senders publish two
simulcast layers (640×360@30 fps ~300 kbit/s, 320×180@15 fps ~90 kbit/s); per
receiver the SFU picks high, low or audio-only from the receiver's loss
reports, switching only at keyframes and probing upward with back-off. The
dominant speaker is computed from the RFC 6464-style audio-level byte in the
clear header (a simplified Volfin–Cohen with a 400 ms hold), so it works on
encrypted audio.

**Revocation reaches calls.** When someone loses a channel mid-call, the
gateway tells the SFU, the SFU drops them, and every remaining sender rotates
its key — demonstrated in `cloud/rtc/demo.sh`, where Alice removes Carol 16 s
into a call and Carol is out at 16.08 s.

**Measured** — three participants through the SFU on loopback, admitted by the
gateway with tokens from `chat call '#design'`, synthetic camera and
microphone, E2EE on, 22 s (`cloud/rtc/demo.sh`):

| receiver ← sender | audio capture→received | jitter | capture→played | video frames | video capture→decoded | lost |
| --- | --- | --- | --- | --- | --- | --- |
| alice ← bob | 2.29 ms | 0.20 ms | 36.0 ms | 648 | 7.28 ms | 0 |
| bob ← alice | 2.34 ms | 0.21 ms | 37.5 ms | 648 | 6.97 ms | 0 |
| carol ← alice | 1.88 ms | 0.42 ms | 35.7 ms | 441 (until removed) | 6.50 ms | 0 |
| carol ← bob | 2.92 ms | 0.76 ms | 32.7 ms | 441 (until removed) | 7.96 ms | 0 |

Dominant speaker on a schedule of Alice 0–4 s, Bob 4–8 s, Carol 8–12 s: the
SFU switched alice → bob → carol → alice → bob, each 0.67–0.69 s after the
turn began (mostly the 400 ms hold). A receiver constrained to 400 kbit/s was
moved to the low layer 1.5 s in; at 150 kbit/s to audio only at 1.9 s, with
984 of 985 audio frames delivered (`cloud/rtc/sfu/demo3.sh OUT 20 400|150`).

## Encryption, honestly

**Chat is not end-to-end encrypted.** The gateway stores messages in Postgres
and searches them there; the server can read them. That is a choice, made for
server-side search, history on a new device without key backup, bots and
assistants that read a channel they were invited to, and retention and export
for organisations — and it is the same choice Slack and Teams make. It is
encrypted in transit only when a TLS-terminating proxy sits in front of the
gateway (TLS is not built in; see "Not built"). The README's line applies:
anything that moves to a server has to say which of the two it gave up.

**Call media is end-to-end encrypted.** Every frame is SFrame (RFC 9605,
AES-128-GCM, checked against the RFC's test vectors) under a per-sender key;
keys are sealed pairwise with X25519 and relayed by the SFU as opaque blobs,
and rotated on every join and leave. The SFU forwards ciphertext, cannot
relabel one person's media as another's, cannot inject media, and cannot
change the header fields bound into each frame.

**The stated limit:** public keys are not bound to anything enrolled in the
account, so an active attacker who controls the SFU or the gateway could
substitute them. A five-group **safety code**, identical at every participant
of an honest call, is what detects it; people have to compare it. The upgrade
is device keys enrolled in the account (the accounts area's device rows are
the natural home), then MLS (RFC 9420) with those as credentials and SFrame
keyed from the MLS exporter per sender — the design Discord's DAVE and Webex
ship; `libdave` has a C API that fits behind `cloud/rtc/pcp`. The SFrame layer
would not change.

If chat ever needs E2EE (a "private space" for an identity that wants it), the
same MLS group can key message encryption, at the cost of server-side search
and bots in those spaces. That is a product decision, listed below.

## Decisions taken

| decision | why |
| --- | --- |
| **Our own gateway, not Supabase Realtime, for fan-out** | Realtime Broadcast has no delivery or ordering guarantee; `postgres_changes` is ordered but authorises every event per subscriber and degrades sharply with RLS at scale; private-channel authorisation is cached until the JWT refreshes, so revocation lags; and a native client would have to speak Phoenix channels anyway. The gateway gets commit order from `pg_notify`, revocation within the transaction that revoked, and a protocol the clients already speak. Realtime stays useful for things that are hints, not history. |
| **A native media protocol, not WebRTC, between Palmy apps** | No SDP, no DTLS handshake, a fixed small header, and a few thousand lines of Odin instead of libwebrtc. What it gives up is browser interop and libwebrtc's years of tuning (NetEQ, GCC, AEC). |
| **E2EE at the frame, independent of transport** | So a later WebRTC bridge for the browser can pass frames through unchanged: browsers can be full E2EE participants through Encoded Transform (RTCRtpScriptTransform), as Jitsi and Discord do. |
| **Slack-style threads, kept** | v1 already had first-class threads with a strong ordering guarantee. Zulip's required topics are the better model for busy async teams; it is listed as an open decision rather than half-done. |
| **Echo cancellation through PipeWire** | The realistic path is PipeWire's `module-echo-cancel` (WebRTC AEC3 underneath), loaded by Palmy's PipeWire config, with the call app targeting its nodes (`--echo-cancel`); speexdsp is markedly worse, and AEC3 in-process needs a C++ shim. The module is not loaded on this machine, so only the routing is tested. |

## Built, and not built

| | status |
| --- | --- |
| spaces, public/private channels, DMs, threads, reactions, edits, deletes | built, end to end |
| invitations across identities and accounts; leave; remove; guests | built, pgTAP + e2e |
| read cursors, unread counts, read receipts | built |
| attachments in Supabase Storage under channel policies | built (512 KiB per file over the chat frame; larger files belong to Drive) |
| full-text search under RLS | built |
| reconnect sync by revision | built |
| calls up to 16 through `palm-sfu`, simulcast tiers, speaker, E2EE | built, measured |
| revocation dropping people from live calls | built, demonstrated |
| CLI per `docs/PALM-CLI.md` (`chat <verb>`, `--json`, exit codes 3/5/6) | built: 21 verbs |
| screen share | works on wlroots compositors; **not** under `apps/wm`, which implements no screen-capture protocol |
| TLS on the gateway | not built: Odin's core has no TLS; deploy behind a TLS-terminating proxy, or wait for the TLS seam cloudkit already has |
| TURN / TCP fallback for the SFU | not built: the SFU binds loopback by default; a public deployment needs a public bind plus TURN (coturn with REST credentials) or a TCP/443 fallback |
| recording | schema only (`rtc_recordings`); with E2EE a recorder must be a participant that holds keys, which is a consent and UX question first |
| mobile push | not built; the gateway knows who is offline and what mentions them, which is what a push sender needs |
| browser participants | not built: a WHIP/WHEP gateway (ICE-lite, DTLS-SRTP, RTP packetisation) passing SFrame frames through |
| federation / Matrix bridge | not built; a bridge would be an ordinary gateway client (like `apps/chatbot`) that speaks Matrix on the other side, and could not carry E2EE across |
| MLS | designed above, not built |
| delay-based bandwidth estimation, last-N, pausing unused layers | not built; loss-based only |
| the chatbot on the cloud | not yet: `apps/chatbot` still speaks v1; it would sign in as an identity and be invited like anyone else |

## Scaling notes

- **One gateway, one mutex, one database connection.** Every request takes
  the lock for a few round trips (≈1 ms on loopback). That is hundreds to low
  thousands of writes a second per gateway, plenty for a team, not for a
  company. The ordering does not depend on the mutex: it comes from the
  channel row lock and `pg_notify`, so the next step is a connection pool and
  per-connection workers, with fan-out still from the one notification stream.
- **Several gateways** can run today against one database: each LISTENs and
  broadcasts to its own clients, and writes from one appear on all. Presence
  is per gateway (each sets it on connect and disconnect); it would want a
  short TTL rather than a boot-time reset.
- **`pg_notify`** carries ids, never content (payloads are capped at 8000
  bytes), and the gateway fetches each changed row once per event, not once
  per recipient. A single Postgres sustains tens of thousands of notifications
  a second; beyond that, partition channels across databases by space.
- **Search** is a GIN index over `to_tsvector('simple', body)`; fine to tens of
  millions of rows. Per-identity ranking and attachments' contents are not
  indexed.
- **The SFU** is single-threaded and forwards with no decode. The O(n²) key
  sealing caps sensible rooms at a few dozen — MLS removes that — and one
  process's forwarding at a few hundred streams. Large meetings want cascaded
  SFUs (one per region, forwarding to each other) and last-N.

## Open decisions for the product

1. **Topics or threads.** Keep Slack-style threads, or adopt Zulip's model —
   every message in a channel has a topic, with per-topic unread and mute. It
   is the better answer to "threads get buried", and it is a schema column plus
   a sidebar level; it is not a migration once there is history.
2. **E2EE chat for some spaces?** Possible with MLS, at the cost of server-side
   search, bots and history on new devices in those spaces.
3. **Read receipts by default.** On now (members see each other's cursors).
   Many teams want them off; it should probably be a per-identity setting.
4. **Who may DM whom.** Any two members of a space can open a DM without an
   invitation (a guest only with people it shares a channel with). That is
   Slack's rule; a stricter product would require an invitation for DMs too.
5. **Browser interop priority.** Whether the browser being built should join
   calls (a WHIP/WHEP bridge) before or after MLS.

## Gaps found in other areas

- **cloudkit** has no constructor for a client around a borrowed bearer token:
  the gateway uploads to Storage as the person, with their access token, and
  has to set a placeholder refresh token to satisfy `signed_in`
  (`cloud/rtc/main.odin`, `storage_client`).
- **apps/wm** implements no screen-capture protocol (`ext-image-copy-capture-v1`
  or wlr-screencopy), so screen share does not work under it.
- **palmy** cannot clip an image to a rounded rectangle, so video tiles have
  square corners; and its frame loop cannot wait on a second fd, so the chat
  window still polls its socket at vsync (TODO.md K4).

## Running it

```sh
cloud/dev/up.sh --name rtc --port-base 61520                  # the stack
cloud/dev/test.sh --name rtc --port-base 61520                # pgTAP, every area
cloud/rtc/demo.sh                                             # three people, a space, a call, a revocation
palm-rtc --e2e --db postgresql://postgres:postgres@127.0.0.1:61521/postgres \
  --api http://127.0.0.1:61520 --jwt-secret … --sfu-secret-file F           # 92 checks
palm-sfu --selftest                                           # 100 checks
call --self-test                                              # 430 checks
chat --selftest --server chat-server.bin                      # v1: 164 assertions
bash cloud/rtc/verify-locks.sh                                # the gateway's lock discipline
chat --cloud-shots DIR; bash cloud/rtc/sfu/shots.sh DIR dark  # screenshots
```

Screenshots: `apps/chat/shots/cloud-*.png` (the window, both themes, and one
frame of the real window against a live gateway) and `apps/call/shots/sfu-*.png`
(grid, speaker, people and encryption panel, screen share).
