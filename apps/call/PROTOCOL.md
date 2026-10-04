# PCP1 — the call transport

The wire format two instances of `call` use to talk to each other. It is
RTP-shaped: a fixed header carrying a sequence number, a timestamp, a payload
type and a frame-boundary marker, followed by an opaque payload. It is not
RTP — there is no SSRC negotiation, no RTCP, no profile registry — and it does
not pretend to be. Where RTP's choices cost this application something, they
have been changed, and each change is explained below.

Implementation: [`proto.odin`](proto.odin). Header round-trips, rejection
cases and fragmentation arithmetic are asserted in `call --self-test`.

## Transport

UDP over **127.0.0.1 only**. Each instance binds one socket, and media and
signalling share it.

```
instance A   bind 127.0.0.1:47811   peer 127.0.0.1:47812
instance B   bind 127.0.0.1:47812   peer 127.0.0.1:47811
```

The bind address is the literal loopback address, never `0.0.0.0`. This
program drives a camera and a microphone; it has no business being reachable
from the network, and `call --self-test` reads the socket's bound endpoint
back and asserts it is `127.0.0.1`. A datagram whose source endpoint is not
the configured peer is counted as rejected and dropped before parsing.

There is no connection, no handshake at the transport layer and no
retransmission. A datagram either arrives or it does not; the jitter buffer
and the reassembler are what make that acceptable.

## Header

24 bytes, big-endian, on every datagram including control messages.

```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|            magic  'P'   'C'   'P'   '1'                       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
| payload type  |     flags     |         sequence              |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                                                               |
+            capture timestamp, microseconds (u64)              +
|                                                               |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                        frame id (u32)                         |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|     fragment index (u16)      |    fragment count (u16)       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                          payload ...                          |
```

| field | size | meaning |
| --- | --- | --- |
| `magic` | 4 | `"PCP1"`. A port on a shared machine receives strays; a packet that is not ours is discarded here. |
| `payload type` | 1 | `0` control, `1` Opus audio, `2` PCM-16 audio, `3` MJPEG video. |
| `flags` | 1 | bit 0 `MARKER`: this is the last fragment of its frame. Bits 1–7 reserved, sent as zero. |
| `sequence` | 2 | Per-stream datagram counter, wrapping. Audio and video count separately, so loss on one is measurable without the other. |
| `capture timestamp` | 8 | `CLOCK_MONOTONIC_RAW` microseconds, taken **at capture**, not at send. |
| `frame id` | 4 | Per-stream frame counter, wrapping. Every fragment of one video frame carries the same id. |
| `fragment index` | 2 | 0-based. |
| `fragment count` | 2 | Total fragments in this frame. `1` for audio and control. |

Payload cap is **1200 bytes**, so the largest datagram is 1224 and stays under
a 1500-byte Ethernet MTU with room for an IP and UDP header. Nothing in this
program leaves the loopback interface, but a framing that would need re-tuning
to do so is not a transport design.

### Why these fields are not RTP's

**A 64-bit timestamp in microseconds, not RTP's 32-bit media clock.** RTP's
timestamp counts samples in the stream's own clock, which is what a mixer
wants and useless for measuring latency: the two ends would have to agree on
an epoch first. Here both instances read `CLOCK_MONOTONIC_RAW`, which on one
machine is the *same clock*, so a receiver subtracts and gets the real
one-way delay with no synchronisation of any kind. Every latency number this
application reports is that subtraction. 64 bits because 32 bits of
microseconds wraps in 71 minutes and a call can outlast that.

**An explicit fragment index and count, not RTP's payload-specific
fragmentation.** RTP leaves fragmentation to each payload format — H.264 has
FU-A, VP8 has its own descriptor. One generic scheme in the header costs four
bytes and means the reassembler does not care what it is reassembling.

**A frame id separate from the sequence number.** With only a sequence number
a receiver infers frame boundaries from the marker bit, which breaks the
moment a marker is lost. An explicit id means a lost marker costs one frame,
not the alignment of every frame after it.

**The marker bit is checked against the fragment counters.** `MARKER` must be
set exactly when `fragment index == fragment count - 1`. A datagram where they
disagree is rejected, because a receiver that trusts one and not the other has
no way to tell a corrupt packet from a short frame.

## Payload types

### 1 — Opus audio

One 20 ms frame per datagram, never fragmented: 48 kHz mono at 32 kbit/s is
about 80–110 bytes. The encoder runs in `OPUS_APPLICATION_VOIP` with in-band
FEC on and an expected packet loss of 5 %.

Because audio is never fragmented, the sequence number *is* the frame number,
and the jitter buffer indexes on it directly.

### 2 — PCM s16le audio

The fallback when `libopus` will not create a codec state: 960 samples, 1920
bytes, one frame per datagram, native-endian signed 16-bit. It is 768 kbit/s
and it is honest — the UI names the codec actually in use rather than claiming
Opus.

### 3 — MJPEG video

One JPEG per frame, 640×360 at 30 fps by default, about 15 KB, so 13
fragments. Every fragment of a frame shares a `frame id`; the last carries
`MARKER`.

MJPEG has no inter-frame prediction, which is both the reason to use it and
the cost of using it. The reason: a lost frame costs exactly one frame, the
receiver is `stb_image` which palmy already has, and there is no decoder state
to desynchronise. The cost: 3.9 Mbit/s where H.264 would use 300 kbit/s. Over
loopback that does not matter; over a real link it would, and the fix is a
real video codec, not a lower frame rate pretending to be one.

The resolution is a choice, not a ceiling. Measured end to end, `--video`
asking for 30 fps:

| | measured | JPEG | decode | wire |
| --- | --- | --- | --- | --- |
| 480×270 | 30.0 fps | 9.6 KB | 0.58 ms | 2.6 Mbit/s |
| **640×360** | **29.9 fps** | **15.1 KB** | **0.94 ms** | **3.9 Mbit/s** |
| 960×540 | 29.9 fps | 24.1 KB | 1.78 ms | 6.4 Mbit/s |
| 1280×720 | 30.0 fps | 41.0 KB | 2.78 ms | 10.7 Mbit/s |

Zero dropped frames and zero partial reassemblies at every one of those: 418
frames sent, 418 decoded, in each case.

### 0 — Control

Signalling, on the same socket, one datagram per message.

```
 0               1               2               3
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|     kind      |     flags     |       name length (u16)       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     display name, UTF-8, ≤64 B                |
```

| kind | | |
| --- | --- | --- |
| 0 | `HELLO` | sent once at startup, so a name is known before anyone dials |
| 1 | `INVITE` | repeated every 400 ms while dialing |
| 2 | `RINGING` | the callee's phone is ringing |
| 3 | `ACCEPT` | answered |
| 4 | `DECLINE` | refused |
| 5 | `BYE` | hung up; sent three times, because its loss leaves the other end looking at a frozen picture until the 5 s peer timeout |
| 6 | `STATE` | mute and camera flags, every 500 ms while connected; doubles as a keepalive. An instance that receives one while idle replies `BYE`, because the peer believes it is in a call that no longer exists |

`flags`: bit 0 muted, bit 1 camera off.

A control message whose `name length` exceeds the datagram is rejected.

## State machine

```
            ┌──────┐  C / dial                 ┌─────────┐
            │ Idle │ ────────────────────────▶ │ Dialing │
            └──────┘                           └────┬────┘
               │  ▲                     ACCEPT ─────┤
     INVITE ───┤  │ H / dismiss                     │ DECLINE, timeout,
               ▼  │                                 │ H / cancel
          ┌─────────┐  Enter / accept        ┌──────▼─────┐
          │ Ringing │ ─────────────────────▶ │ Connecting │
          └────┬────┘                        └──────┬─────┘
               │ H / decline, timeout               │ first media datagram
               │                                    ▼
               │                             ┌───────────┐
               └───────────────┐             │ Connected │
                               ▼             └─────┬─────┘
                          ┌───────┐  BYE, H, peer  │
                          │ Ended │ ◀──────────────┘
                          └───────┘       timeout (5 s)
```

Capture and playback processes start on entry to `Connecting` and stop on
leaving `Connected`, so nothing holds a device when there is no call.

`Connecting` ends when the *first media datagram* arrives, not when `ACCEPT`
does — a call is not connected until media is flowing, and saying otherwise
is how an app ends up showing "Connected" over a black rectangle.

**Glare.** If both ends dial at the same moment, each receives `INVITE` while
in `Dialing`. The instance with the lower bound port concedes and answers; the
other's `Dialing` is satisfied by the resulting `ACCEPT`. No extra round trip,
no extra state.

## Jitter buffer

Audio only. Implementation and the full rationale: [`jitter.odin`](jitter.odin).

| | |
| --- | --- |
| shape | ring of 16 slots indexed by `sequence % 16`, one explicit playout cursor |
| capacity | 16 × 20 ms = **320 ms** |
| target depth | 2 frames = **40 ms** before playout starts |
| ceiling | 3 frames = **60 ms**, enforced by trimming the oldest |
| concealment | `opus_decode(dec, nil, 0, …)` — Opus' own packet-loss concealment |
| fallback concealment | 20 ms of silence, faded in from the previous sample over 2 ms |

The target is 40 ms because the measured one-way delay on this transport is
0.2–4.4 ms. Ten times the observed jitter is a cushion; more than that is
latency bought for nothing. On a link with real jitter this is the number to
raise, and it is one constant.

The ceiling exists because the whole chain is self-clocked: ffmpeg paces
capture, `pw-play` paces playout, and two independent clocks accumulate. How
badly depends entirely on how well they agree, and it is the sharpest
diagnostic in the whole program:

| capture pacing | clock error | standing hold | trimmed in 30 s |
| --- | --- | --- | --- |
| `ffmpeg -re` | +5.9 % | 42 ms, at the ceiling | **20** |
| `arealtime` | −0.4 % | 20–40 ms | **0** |

`jb_trim` discards the **oldest** frames back to the target and counts every
one; dropping the newest would keep the stale audio and throw away what the far
end just said. It is the blunt version of the time-scale modification a
production implementation would do instead — and the counter reading zero is
what says the pacing upstream is right, which is why it is on screen.

Behaviour, all of it asserted in the self-test:

- **In order** — stored, played in turn.
- **Reordered** — stored at its own index and played in sequence order. During
  preroll the cursor follows the *oldest* sequence held rather than the first
  to arrive, so a reordered opening burst is not discarded wholesale.
- **Duplicate** — the slot already holds that sequence; counted and ignored.
- **Lost** — the cursor's slot is empty but later frames are present: one
  concealment frame is emitted and the cursor advances. Exactly one
  concealment per hole.
- **Too late** — sequence is behind the cursor. Discarded and counted; playing
  it would be playing audio out of order, which is worse than the gap already
  concealed in its place.
- **Too far ahead** — beyond the ring. The buffer resynchronises on the new
  sequence rather than concealing its way through the gap one 20 ms step at a
  time.
- **Starved** — nothing to play, or below the target depth. The cursor holds
  and the player's pipe is simply not fed.
- **Over the ceiling** — more than 60 ms held. The oldest frames are trimmed
  back to the target and counted.

There is **no playout clock in this program**. `pw-play` consumes its stdin at
exactly 48 kHz, so the pipe is the clock: frames are popped only when the pipe
accepts them. A clock of our own would drift against the sound card, and the
drift would be audible as a click every few seconds.

But "when the pipe accepts them" is not by itself a rate limit, because
`pw-play` reads eagerly into a ring of its own. Feeding it as fast as the pipe
would take it left **90 ms** of standing queue inside the player — latency with
no resilience to show for it. So the playout loop stops once the player is
holding `PLAYOUT_TARGET_US` (40 ms), computed as bytes written minus the bytes
a constant 48 kHz has consumed since the first write. That is arithmetic over
a known rate rather than an estimate, and it is a *lower* bound: `pw-play`
primes its stream before it starts draining, so the subtraction credits it
with slightly more than it has actually played.

Video has no jitter buffer, by choice. A late video frame can simply be shown
late or dropped — there is no continuity to protect — so the reassembler
delivers frames as they complete and the renderer shows the newest one.

## Reassembly

Four slots, keyed by frame id, each with a 64-bit fragment bitmap. A frame
completes when every bit is set *and* the last fragment has been seen, which
is what fixes the total length — only the last fragment may be short.

Slots are reclaimed by frame-id distance, not by a timer: when all four are
busy the one with the oldest id is evicted and counted as dropped. A fragment
for a frame already delivered, or for one older than the last delivered, is
counted as late and discarded.

## Counters

Every one of these is on screen in the Statistics panel, because a call that
is degrading should say so rather than merely feel wrong: packets and kbit/s
each way, rejected datagrams, audio latency now / mean / min / max with a
sample count, jitter depth held, concealed frames and loss percentage,
duplicates, late packets, resyncs, capture-backlog drops, measured video
frame rate in and out, JPEG size, decode cost, frame latency, and reassembly
completed / partial / late.

## Measured

Two instances, synthetic sources, 30 s call, loopback, both ends headless
(`call --headless`) so the rasteriser is not competing for the CPU. Produced
by the summary `--headless` prints when it exits.

| | |
| --- | --- |
| audio, framer → handed to the player | mean **12.9 ms**, min 0.5, max 32.3, n = 1498 |
| audio, player queue at hand-over | mean **24.3 ms**, peak 48.2 |
| audio, **framer → loudspeaker** | **≈ 37 ms**, the sum of those two |
| audio, capture → received | mean **3.2 ms** — the UDP hop plus the Opus round trip |
| capture pipe backlog | 33 ms steady, 40 ms peak, measured with `FIONREAD` |
| audio frames | **1498 sent, 1498 played** — nothing dropped anywhere |
| jitter buffer | **0 concealed, 0 duplicate, 0 late, 0 resync, 0 trimmed** |
| video | **29.9 fps** out and in, 640×360, **0 failed decodes** |
| video, capture → decoded | mean **3.8 ms** |
| JPEG frame | 15.1 KB, **0.94 ms** to decode through stb_image |
| reassembly | 898 complete, 0 partial, 0 late |
| transport | 14 062 datagrams / 14.9 MB each way in 30 s, 0 rejected, **≈ 4 Mbit/s** |

### What the 37 ms is made of, and what it was

The single biggest cost in this pipeline turned out not to be the codec, the
socket or the jitter buffer. It was the capture source's clock.

`ffmpeg -re` gates on wall clock, and it overshoots: measured directly, it
produced **8.48 s of audio in 8.01 s** — 5.9 % fast. A capture clock running
5.9 % faster than the sound card means 5.9 % of the audio has to be discarded
somewhere, and the jitter buffer's ceiling duly discarded it: **20 audible
20 ms skips in a thirty second call**, with the end-to-end figure sitting at
96 ms because every queue in the chain was standing full.

Pacing with the `arealtime` filter instead, which counts samples rather than
watching a clock, lands within 0.5 %. Every queue in the chain then sits near
empty instead of near full, and the result is the table above: 37 ms, and
1498 frames captured against 1498 frames played.

What remains is honest architecture cost — a microphone and a loudspeaker that
are both separate processes on the far side of a pipe cost three queues where
an in-process audio callback would cost one. The wire itself is 3 ms.

Loopback has no loss and almost no jitter, so the concealment and reordering
paths do not fire in a live call — which is exactly why the self-test drives
them directly, with deliberately dropped, duplicated and reordered packets.
