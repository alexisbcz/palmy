# PCP1 — the call transport

The wire format two instances of `call` use to talk to each other. It is
RTP-shaped: a fixed header carrying a sequence number, a timestamp, a payload
type and a frame-boundary marker, followed by an opaque payload. It is not
RTP — there is no SSRC negotiation, no RTCP, no profile registry — and it does
not pretend to be. Where RTP's choices cost this application something, they
have been changed, and each change is explained below.

Video codecs are negotiated — H.264 or MJPEG, decided by two offers and a pure
function, with MJPEG as a floor that cannot be negotiated away. See **Video
codec negotiation**, and **Loss, and the keyframe request** for what a
predictive codec costs and what is done about it.

Implementation: [`proto.odin`](proto.odin). Header round-trips, rejection
cases, fragmentation arithmetic, codec negotiation, the keyframe flag and the
loss path are asserted in `call --self-test` — 345 checks, up from 229 before the codec work
(430 now that it also covers SFU mode).

**Calls with more than two people** go through `palm-sfu` and speak PCP2, a
superset of this header, end-to-end encrypted with SFrame. That is the second
half of this document: see **PCP2** below.

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
| `payload type` | 1 | `0` control, `1` Opus audio, `2` PCM-16 audio, `3` MJPEG video, `4` H.264 video. |
| `flags` | 1 | bit 0 `MARKER`: this is the last fragment of its frame. bit 1 `KEYFRAME`: this frame needs no earlier frame to decode. Bits 2–7 reserved, sent as zero. |
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

**A keyframe bit in the generic header, not in a codec descriptor.** RTP puts
this in each payload format: H.264 wants the NAL type read out of the payload,
VP8 has a `P` bit in its own descriptor. One flag in the header means the
reassembler and the loss logic never look inside a payload, and it means
*MJPEG sets it on every frame* — which is the literal truth about MJPEG, and
is why the receiver's loss path below needs no special case for it. It is set
on **every fragment** of the frame rather than only the first, so losing the
first fragment does not also lose the knowledge of what was lost.

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

One JPEG per frame, 640×360 at 30 fps, about 15.8 KB, so 14 fragments. Every
fragment of a frame shares a `frame id`; the last carries `MARKER`, and all of
them carry `KEYFRAME`, because every MJPEG frame is one.

MJPEG has no inter-frame prediction, which is both the reason it was the first
codec here and the reason it is no longer the default. The reason: a lost frame
costs exactly one frame, the receiver is `stb_image` which palmy already has,
and there is no decoder state to desynchronise. The cost, measured: **3864
kbit/s**, and 14.9 MB on the wire in a thirty-second call.

MJPEG is kept, and is the floor of the codec negotiation, for three reasons.
It is what a peer that has never heard of the negotiation gets. Every frame is
independent, so it is the thing to fall back to when the H.264 loss path is
under suspicion. And it needs no child process on the receive side at all.

Resolution is a choice, not a ceiling. Measured end to end, `--video` asking
for 30 fps:

| | measured | JPEG | decode | wire |
| --- | --- | --- | --- | --- |
| 480×270 | 30.0 fps | 9.6 KB | 0.58 ms | 2.6 Mbit/s |
| **640×360** | **29.9 fps** | **15.8 KB** | **1.00 ms** | **3.9 Mbit/s** |
| 960×540 | 29.9 fps | 24.1 KB | 1.78 ms | 6.4 Mbit/s |
| 1280×720 | 30.0 fps | 41.0 KB | 2.78 ms | 10.7 Mbit/s |

Zero dropped frames and zero partial reassemblies at every one of those.

### 4 — H.264 video

The default, and the reason the cost above is now a historical note.

`libx264`, **baseline profile, `-preset ultrafast -tune zerolatency`**, no
B-frames, rate-targeted at **300 kbit/s**. One Annex-B access unit per frame,
about 1.2 KB, so one or two fragments; a keyframe is 5–7 KB, so five or six.
Measured at 640×360 @ 30 fps: **1.21 KB a frame, 296 kbit/s, 898 frames sent
and 898 decoded in thirty seconds.** That is **13× less** than MJPEG for the
same picture, and 1.3 MB on the wire against 14.9 MB.

Baseline and `zerolatency` are not timidity. Lookahead is latency; B-frames
are reordering, which is latency a receiver cannot give back. With neither, an
access unit leaves the encoder in the frame it was captured in, and the
measured capture-to-rendered figure below is a frame interval, not a GOP.

**Framing.** The encoder is asked for access-unit delimiters
(`-x264-params aud=1`), so a frame ends where the next AUD begins and the
splitter is a byte scan — the same shape as MJPEG's `FF D8 … FF D9`. Without
them, finding a frame boundary in Annex-B means parsing slice headers for
`first_mb_in_slice`, and at `-tune zerolatency` x264 emits five slices per
frame. The cost of the delimiter being at the head rather than the tail is one
frame of send latency, which MJPEG does not pay and which shows up in the
table below.

**Parameter sets.** `repeat-headers=1` plus `-bsf:v dump_extra=freq=keyframe`
puts SPS and PPS in front of **every** keyframe. Without them the parameter
sets exist only in the first datagrams of the call, and losing those loses the
stream for its whole duration — a failure that lasts a call rather than a
frame.

**Decoding.** palmy decodes JPEG in process through stb_image and nothing
else, so the H.264 receiver is a child process: `ffmpeg -f h264 -i -` with
Annex-B on stdin and raw BGRA frames on stdout, one frame per access unit,
inter-frame state kept between them. BGRA little-endian is byte-for-byte the
`0xAARRGGBB` palmy's rasteriser wants, so publishing a frame is a `memcpy`
rather than a conversion loop.

Three things in that command line are worth 60 ms between them, and all three
were measured rather than guessed:

| | measured cost of getting it wrong |
| --- | --- |
| `-threads 1` | the h264 decoder is frame-threaded by default, and frame threading holds output back one frame per thread: **68 ms** of standing latency for a decode that costs under a millisecond |
| a trailing 6-byte AUD sentinel after every frame written | ffmpeg's Annex-B parser will not emit an access unit until it has seen the start of the next one. The sentinel ends it immediately and then parses as an access unit with no picture in it. Worth **34 ms** |
| `-probesize 32 -analyzeduration 0` | otherwise the first frame waits while ffmpeg works out what the stream is |

With all three, the decoder's own contribution is **5.0 ms** and the
capture-to-rendered figure is **7.6 ms**. Without them it was 68 ms. "We used
ffmpeg" and "we used ffmpeg correctly" are a factor of nine apart.

A fourth number came from the kernel rather than the codec. A decoded 640×360
BGRA frame is 921,600 bytes, 27 MB/s at 30 fps, and **a frame loop drains at
most one pipe-full per tick** — once the pipe is empty the read returns
`EAGAIN` and the tick is over. With a pipe's default 64 KiB that is a ceiling
of 16 MB/s, and the stream arrived at **exactly 17 fps with three seconds of
standing latency**. `F_SETPIPE_SZ` is capped at `/proc/sys/fs/pipe-max-size`
(1 MiB here) for an unprivileged process and *fails silently* above it, so the
request now halves until the kernel accepts it. At 1 MiB the headroom is 2.3×
even at the 60 Hz of a windowed call. Above roughly 512×512 a frame no longer
fits 1 MiB, so the decoder is asked to scale its output down to what does;
that caps the *displayed* resolution, not the encoded one, and is stated here
rather than hidden.

### 0 — Control

Signalling, on the same socket, one datagram per message.

```
 0               1               2               3
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|     kind      |     flags     |       name length (u16)       |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                     display name, UTF-8, ≤64 B                |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|  codec offer  |   <- optional; absent means "MJPEG only"
+-+-+-+-+-+-+-+-+
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
| 7 | `KEYFRAME` | *send me a frame I can decode on its own.* This protocol's PLI; see **Loss** below. It says nothing about the call's state, and is the one kind an idle instance does not answer with `BYE` |

`flags`: bit 0 muted, bit 1 camera off.

A control message whose `name length` exceeds the datagram is rejected.

## Video codec negotiation

Every signalling message except `DECLINE`, `BYE` and `KEYFRAME` carries a
one-byte **offer**: the set of video codecs the sender can *decode*.

| bit | codec |
| --- | --- |
| 0 | MJPEG — mandatory to implement |
| 1 | H.264 |

Both ends compute the codec as the same pure function of the two offers:
intersect, then prefer H.264 over MJPEG. Because the function is symmetric and
both ends have both offers, **there is no answer message and no extra round
trip** — the choice is made independently at each end and cannot disagree.
`call --self-test` checks the symmetry over every pair of offers, because a
disagreement here is a call where each end sends something the other cannot
decode and there is nothing on the wire to correct it.

MJPEG is bit 0 and is mandatory, which makes the intersection **never empty**:
an offer of zero, or an offer of H.264 alone meeting an offer of MJPEG alone,
both resolve to MJPEG rather than to no video. Negotiation cannot fail.

### What an MJPEG-only peer gets

A working call, at MJPEG's bitrate, with neither end doing anything special.
Three cases, and they are the whole of it:

| this end offers | peer offers | result |
| --- | --- | --- |
| H.264 + MJPEG | H.264 + MJPEG | H.264 both ways |
| H.264 + MJPEG | MJPEG | **MJPEG both ways** |
| H.264 + MJPEG | *nothing — no offer byte at all* | **MJPEG both ways** |

The third case is what makes the extension safe rather than merely
compatible-looking. The offer sits **after** the variable-length name, and
`read_control` validates only that the name fits inside the datagram, so a
parser that has never heard of the field accepts the message and ignores a
byte it did not consume. A new parser reads a *missing* offer as MJPEG-only,
which is the correct reading of silence: MJPEG is the only codec every version
of this program has ever carried.

`--video-codec mjpeg` restricts this instance's offer to MJPEG, which is how
the MJPEG-only peer in the measurements below is produced from the same binary.
Measured, one end `auto` and the other `mjpeg`: both ends independently chose
MJPEG, **358 frames sent and 358 decoded each way, no loss, no partial
reassemblies.**

The receiver is driven by the *payload type on each datagram*, not by what it
negotiated, so an instance decodes whatever actually arrives. The negotiation
decides what it sends.

Renegotiation is handled too, although it cannot normally happen:
`Connecting` is only reachable through an `INVITE` or an `ACCEPT` and both
carry the offer. But a peer that restarts mid-call, or one whose first control
message was lost, would otherwise sit on the MJPEG floor for the rest of the
call, so the comparison is made once a frame and the encoder is restarted if
the answer has changed.

## Loss, and the keyframe request

This is what H.264 costs and what is done about it.

MJPEG frames are independent: a lost frame cost exactly one frame, and there
was no decoder state to protect. H.264 frames predict from their predecessors,
so **a lost packet damages every frame after it until the next keyframe** —
and feeding predicted frames to a decoder whose reference is missing produces
a dissolving smear that looks exactly like a broken application. Three
mechanisms, in the order they fire:

**1. A keyframe every 2 seconds.** `-g 60 -keyint_min 60 -sc_threshold 0`, so
the interval is exact rather than wherever the picture happens to cut — which
is what makes the worst case a number. SPS and PPS ride in front of every one
of them. Two seconds rather than one because a keyframe is 5–7 KB against
1.2 KB for a predicted frame, so one a second spends a fifth of a 300 kbit/s
budget on frames nobody needed; the request below makes the interval a backstop
rather than the mechanism.

**2. The receiver notices, and stops.** Frame ids are dense and every fragment
of a frame carries the same one, so a completed frame whose id is not its
predecessor's plus one means a frame was lost — on the wire, or evicted
half-assembled by the reassembler; the two are the same thing here. The
receiver then feeds the decoder **nothing** until a frame arrives with
`KEYFRAME` set. The picture freezes on the last good frame instead of
dissolving, and `frames_skipped` counts exactly what that cost.

A receiver also starts a call in this state. An H.264 decoder cannot decode
anything before its first IDR, and getting that wrong was measurable: a call
whose first keyframe was lost fed fifty predicted frames to a decoder with no
parameter sets, which answered `non-existing PPS 0 referenced` fifty times and
produced no picture at all until the next keyframe interval came round.

**3. The receiver asks — `KEYFRAME`, this protocol's PLI.** One datagram on
the same socket, rate limited to one every 200 ms so a burst of loss is one
request rather than a request storm.

The sender's half is blunt and is stated as blunt. **There is no way to ask a
running `ffmpeg` for a keyframe**: its CLI takes no commands,
`-force_key_frames` is fixed at startup, and the encoder is on the far side of
a pipe we only read. So honouring a request means **cycling the encoder
process** — a fresh `ffmpeg` emits SPS, PPS and an IDR as its first access
unit. Measured, that costs **2.4 frames, about 79 ms**, each time, and with
the synthetic source the pattern visibly restarts. It is therefore rate limited
to four a second and budgeted at 160 in a call, both counted on screen.

An in-process encoder would set `pict_type = I` on one frame and cost nothing,
and that is the single strongest argument for linking `libx264` rather than
spawning it. x264's periodic intra refresh (`intra-refresh=1`) is the other
real answer — a moving band of intra blocks in every frame, so damage
self-heals within one refresh cycle with no keyframe spike at all — but it
removes IDRs entirely, and with them any point at which a receiver can
knowingly resume. The keyframe-plus-request design was chosen because it is
the one whose worst case is a number.

### Measured, with loss injected on purpose

Loopback does not lose packets, so `--loss N` drops N of every thousand
outgoing **video** fragments with a fixed seed — signalling is left alone, so
a test of the video loss path is not also a test of the state machine.
`--no-keyframe-request` turns the request off, which is what makes the second
column a measurement of the request rather than a claim about it.

Thirty seconds, 640×360 @ 30 fps, 2 % of video fragments dropped — a brutal
rate, chosen so the mechanism is visible in half a minute:

| | requests on | requests off |
| --- | --- | --- |
| gaps detected | 34 | 34 |
| keyframe requests sent | 38 | 0 |
| keyframes forced by the sender | 33 | 0 |
| **frames lost to waiting** | **76** | **540** |
| per gap | **2.2 frames ≈ 75 ms** | 15.9 frames ≈ 530 ms |
| frames decoded of those that arrived whole | 707 / 783 | 322 / 862 |
| measured frame rate in | 25.0 fps | 8.0 fps |

**Seven times fewer frames lost to waiting**, and the frozen interval goes from
half a second to under a tenth. The sender pays for it: 33 encoder restarts
took its send rate from 30.0 fps to 27.0 fps.

At 0.5 % fragment loss, which is closer to a real link, it is barely visible:
11 gaps, 11 requests, **10 frames** lost to waiting in thirty seconds — under a
frame per gap — and 30.0 fps in.

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

**The reassembler does not know what a codec is, and adding H.264 did not
teach it.** It has no case for a payload type, never reads a payload byte, and
reassembles a 1.2 KB access unit and a 16 KB JPEG with the same arithmetic.
That is what the explicit fragment index and count in the header bought: RTP
would have needed an H.264-specific FU-A mode here, and the only thing in this
application that changed when a predictive codec arrived was the receiver's
*policy* about which completed frames are safe to decode — which lives in
`video.odin`, above the reassembler, and is driven by one header flag.

## Counters

Every one of these is on screen in the Statistics panel, because a call that
is degrading should say so rather than merely feel wrong: packets and kbit/s
each way, rejected datagrams, audio latency now / mean / min / max with a
sample count, jitter depth held, concealed frames and loss percentage,
duplicates, late packets, resyncs, capture-backlog drops, the video codec in
use and both offers that chose it, measured video frame rate in and out, frame
size now and mean, decode cost, frame latency, reassembly completed / partial
/ late, keyframes out and in, and — the H.264 loss story in four numbers —
gaps detected, keyframes asked for, keyframes forced for a peer, and frames
skipped while waiting for one.

## Measured

Two instances, synthetic sources, 30 s call, loopback, both ends headless
(`call --headless`) so the rasteriser is not competing for the CPU. Produced
by the summary `--headless` prints when it exits.

| | |
| --- | --- |
| audio, framer → handed to the player | mean **12.4 ms**, min 0.5, max 31.7, n = 1498 |
| audio, player queue at hand-over | mean **20.8 ms**, peak 44.5 |
| audio, **framer → loudspeaker** | **≈ 33 ms**, the sum of those two |
| audio, capture → received | mean **2.6 ms** — the UDP hop plus the Opus round trip |
| capture pipe backlog | 13 ms steady, 40 ms peak, measured with `FIONREAD` |
| audio frames | **1498 sent, 1498 played** — nothing dropped anywhere |
| jitter buffer | **0 concealed, 0 duplicate, 0 late, 0 resync, 0 trimmed** |
| video | **30.0 fps** out and in, 640×360, **0 failed decodes** |
| video, capture → decoded | mean **7.6 ms** |
| H.264 frame | 1.21 KB, **5.0 ms** through the decoder child |
| keyframes | 15 in 30 s, one every 2 s exactly |
| reassembly | 898 complete, 0 partial, 0 late |
| transport | 2 869 datagrams / 1.3 MB out in 30 s, 0 rejected, **≈ 350 kbit/s** |

### Before and after: MJPEG against H.264

The same binary, the same thirty-second call, the same synthetic sources, the
same two headless peers. The only difference is `--video-codec mjpeg` on both
ends. Everything in this table was printed by `--headless` on the way out.

| | MJPEG | H.264 | |
| --- | --- | --- | --- |
| frames sent / decoded | 898 / 898 | 898 / 898 | nothing dropped either way |
| measured fps out / in | 29.9 / 29.9 | **30.0 / 30.0** | |
| mean frame | 15.76 KB | **1.21 KB** | **13.0× smaller** |
| video on the wire | 3864 kbit/s | **296 kbit/s** | **13.1× less** |
| datagrams out, 30 s | 14 062 | **2 869** | 4.9× fewer |
| bytes out, 30 s | 14.9 MB | **1.3 MB** | |
| decode cost | 1.00 ms (stb_image, in process) | 5.02 ms (ffmpeg child, hand-over to frame-back) | |
| **capture → rendered** | **3.41 ms** | **7.59 ms** | +4.2 ms |
| keyframes | every frame | every 2 s | |
| reassembly | 898 / 0 / 0 | 898 / 0 / 0 | complete / partial / late |
| audio frames | 1498 / 1498 | 1497 / 1496 | unchanged: video does not touch it |
| audio, framer → loudspeaker | 37.2 ms | 38.2 ms | within run-to-run noise |
| jitter buffer | 0 concealed, 0 trimmed | 0 concealed, 0 trimmed | |

**The headline is 300 kbit/s where the old number was 3.9 Mbit/s** — the figure
this document named as the cost of MJPEG, now paid off, and measured at
296 kbit/s against a 300 kbit/s target.

**What it cost is 4.2 ms of video latency**, from 3.4 ms to 7.6 ms. Where that
goes is worth stating exactly, because none of it is the codec:

| | |
| --- | --- |
| ~1.3 ms | the access-unit delimiter is at the *head* of a frame, so a frame can only be cut once the next one has started. MJPEG's `FF D9` is at the tail, and could be sent the instant it arrived |
| ~1.5 ms | the decoder is a process on the far side of two pipes rather than `stb_image` in this one |
| ~1.4 ms | one more 921 KB frame copy, out of the decoder's pipe and into a palmy `Image` |

Seven milliseconds of video latency against an audio path of 38 ms is not a
trade anybody notices. The 68 ms it would have been with ffmpeg's defaults very
much is, which is why the three flags that avoid it are in the payload-type
section above with their individual costs attached.

**What it also cost is the loss story**, which MJPEG did not need at all. That
is the **Loss** section above, with its own measurements.

### What the 33 ms is made of, and what it was

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
empty instead of near full, and the result is the table above: 33 ms, and
1498 frames captured against 1498 frames played.

Those figures are from two headless peers. A **windowed** call pays more,
because the media pump runs once per UI frame and inherits the frame loop's
jitter: a 50 ms hitch in the compositor delivers three audio frames at once,
the far jitter buffer swells past its ceiling, and the ceiling trims. Measured
over the 45 s demo recording that is **about 1.4 trimmed frames a second** —
roughly 2.8 % of the audio — against **zero** between two headless peers. The
counter is on screen for exactly this reason. Raising `JB_MAX_HOLD` from 3
frames to 4 would roughly halve it for 20 ms more latency; 60 ms and a visible
counter is the operating point chosen here, not an accident.

H.264 gives the windowed case a second thing to pay for, and it is the same
shape as the first. The decoder is a child process drained once per UI frame,
so a frame does not become visible until the next tick after it came out —
which at 60 Hz is up to 16.7 ms, and at the headless 250 Hz is 4 ms. Read off
the Statistics panel during the 55-second demo recording against the same
numbers from two headless peers:

| | headless, 250 Hz | windowed, 60 Hz |
| --- | --- | --- |
| decode cost (hand-over to frame back) | **5.0 ms** | 22–31 ms |
| capture → rendered | **7.6 ms** | 37–49 ms |
| measured frame rate in | **30.0 fps** | 23.5–29.3 fps |

Roughly 30 ms of that is the pump interval and the compositor's jitter on top
of it, and none of it is the codec: MJPEG decodes in process and pays only the
jitter. The throughput ceiling moves the same way — a frame loop takes at most
one pipe-full per tick, so the decoder's ceiling is *pipe capacity × tick
rate*, which is 250 MB/s headless and 62 MB/s windowed against the 27 MB/s a
640×360 BGRA stream needs. Nine times the headroom becomes 2.3 times, and a
compositor hitch eats into it directly.

The remedy, if it ever matters, is the one the latency section already names
for a different reason: a decoder linked into this process rather than spawned
behind a pipe. Both of H.264's costs here — the keyframe that can only be
forced by restarting a process, and the frame that can only be collected once
a tick — are the price of the codec being on the far side of a pipe, not the
price of the codec.

What remains is honest architecture cost — a microphone and a loudspeaker that
are both separate processes on the far side of a pipe cost three queues where
an in-process audio callback would cost one. The wire itself is 3 ms.

Loopback has no loss and almost no jitter, so the concealment and reordering
paths do not fire in a live call — which is exactly why the self-test drives
them directly, with deliberately dropped, duplicated and reordered packets.

## A hazard worth writing down

Capture and playback are child processes on pipes, and on this toolkit those
pipes are fragile in a way that has nothing to do with the protocol.

**Resizing a palmy window closes a descriptor palmy does not own.** Float and
resize a window three seconds into a call and both ends lose their
microphone — `read()` returns `EBADF`, the capture child is gone, and the only
symptom is a level meter that stops moving. It reproduces every time, and it
cost one demo recording: thirty-five seconds of a call with video flowing, two
dead microphones, and nothing on screen that said so.

Two defences, both in this application, because `palmy/` is not ours to patch:

* Every pipe descriptor is moved above `FD_FLOOR` (64) with
  `F_DUPFD_CLOEXEC` as soon as the child has its copy, out of the range a
  stale close can reach. `call --selftest` asserts it.
* `supervise_media` notices a dead capture or playback process, announces it
  in the activity log and on stderr, and restarts it — at most five times a
  call, a second apart, with the count on screen. A microphone that stops is
  the worst failure a call application can have, because the only symptom is
  the other person saying "hello?".

## Running it

```sh
# two windows, calling each other, synthetic sources
./call.bin --bind 47811 --peer 47812 --name Alice --autocall &
./call.bin --bind 47812 --peer 47811 --name Bob   --autoanswer &

# the far end with no window, which is how the measurements above were taken
./call.bin --headless --bind 47812 --peer 47811 --name Bob --autoanswer --quit-after 30

# the pipeline tests, no compositor, no window
./call.bin --selftest        # 345 checks

# the same call on MJPEG, which is also how an MJPEG-only peer is simulated
./call.bin --headless --bind 47812 --peer 47811 --autoanswer --video-codec mjpeg

# the loss path, measured rather than asserted: 2 % of video fragments dropped
./call.bin --headless --bind 47811 --peer 47812 --autocall --loss 20 --quit-after 30

# the real interface rendered offscreen with the media pipeline live
./call.bin --bind 47811 --peer 47812 --autocall --shot /tmp/call --shot-at 6,10:d

# the demo
bash record.sh demo.mp4 demo.txt
```

`record.sh` is this application's own recorder rather than
`apps/tools/headless-record.sh`, for one reason: a call needs **two** windows
side by side and the shared recorder starts one binary and fullscreens one
window. Everything else about it is the shared recorder's design and is worth
restating, because it is what made the difference: it starts its own headless
`sway` with its own Wayland socket, its own virtual output and its own seat, so
nothing appears on the user's screen, no focus can be stolen, no other agent's
window can end up in frame, and there is no shared lock to queue behind.

Neither instance is given `--allow-real-devices` anywhere in that list. The
recording and every measurement in this document were taken on `testsrc2`,
SMPTE bars, and a 440 Hz tone — `resolve_capture` substitutes the synthetic
source for anything that touches hardware unless that flag is present, and
`call --selftest` asserts that the command lines it produces for **both**
codecs name no `/dev/video`, no `v4l2`, no `pulse` and no `alsa`. The H.264
decoder's command line is asserted the same way: it has no input of its own at
all.

---

# PCP2 — calls with more than two people, through palm-sfu

Everything above is the two-party call: one socket, one peer, loopback only.
This part is the multi-party call, which is a different topology and so a
different header, built from the same engines.

```
           join token (from the chat gateway's call_join)
               │
 call A ──PCP2──┐                       ┌──PCP2── call B
                ├── palm-sfu (UDP) ─────┤
 call C ──PCP2──┘   stamps sources,     └──PCP2── call D
                    picks a layer per receiver,
                    names the dominant speaker,
                    relays sealed keys it cannot open
```

Implementation:

| | |
| --- | --- |
| [`cloud/rtc/pcp/`](../../cloud/rtc/pcp) | the shared library: header, control framing, SFrame, key sealing, safety code, dominant speaker, tier policy, join tokens |
| [`cloud/rtc/sfu/main.odin`](../../cloud/rtc/sfu/main.odin) | `palm-sfu` |
| [`room.odin`](room.odin), [`room_ui.odin`](room_ui.odin) | the client side of SFU mode in this app |

`call --self-test` runs the library's checks too: **430 checks** now, up from
345 (58 library checks, 23 for the client's PCP2/SFrame path through a relay
that plays the SFU, 4 for echo-cancel routing). `palm-sfu --selftest` runs the
library's checks and then a real SFU on a loopback port with fake participants
speaking PCP2 over real sockets: **100 checks**.

What is reused unchanged from the two-party path: the capture processes, the
Opus encoder, the H.264 encoder and its keyframe-by-restart, the jitter buffer,
the reassembler, the H.264 decoder child. `send_media` has one new branch —
when the session belongs to a room, frames go to `room_send_media` instead of
to a peer — and the video encoder takes a per-instance size, rate and bitrate
so two of them can run.

## Joining

The chat gateway (`cloud/rtc`) decides who may join a call: it checks, as the
caller's identity-scoped Postgres session, that the identity can post in the
call's channel, records the participation, and mints a **join token**:

```
token   = b64url(payload) "." b64url(HMAC-SHA256(secret, b64url(payload)))
payload = {"v":1,"call":…,"ch":…,"id":…,"handle":…,"name":…,"color":…,"exp":…,"e2ee":true}
```

The token lives 60 seconds. The SFU holds the secret and nothing else — no
database credentials, no account keys, no media keys — and admits exactly the
identity a valid, unexpired token names into exactly the call it names. A
participant's session outlives its token: the token opens the door, it is not
a lease. An address that has not joined gets no answer at all, to anything, so
the port is not an oracle.

```
call --sfu 127.0.0.1:47900 --join-token TOKEN
```

The call app needs no database and no chat connection: display names, handles
and identity colours of everyone in the call come from the SFU's roster, which
comes from their tokens.

The SFU also keeps an optional control link to the gateway (`--gateway
HOST:PORT`, the chat wire framing, authenticated by `HMAC(secret,
"sfu-hello:"+ts)`), over which it reports each room's roster (`sfu_room`), its
end (`sfu_end`) and its dominant speaker (`sfu_speaker`), and receives
`sfu_kick` when someone's channel membership is revoked mid-call. A kick is
immediate: the participant is told, removed, and — because everyone else sees
the new roster — every remaining sender rotates its key, so the person who was
removed cannot decrypt anything said after.

## Header

```
 0       4    5     6     8                 16      20     22     24    26     27     28
+-------+----+-----+-----+-----------------+-------+------+------+-----+------+------+
| "PCP2"| pt |flags| seq | capture ts (us) | frame | frag |nfrag | src |layer |level |
+-------+----+-----+-----+-----------------+-------+------+------+-----+------+------+
```

PCP1's 24 bytes, with four more:

| field | | |
| --- | --- | --- |
| `src` | u16 | the sender, **stamped by the SFU** from the session the datagram arrived on. A sender writes 0; whatever it writes is overwritten, so nobody can speak as somebody else. |
| `layer` | u8 | simulcast layer of a video frame: 0 high, 1 low |
| `level` | u8 | RFC 6464's audio-level octet: bit 7 voice activity, low seven bits the level in −dBov (0 loudest, 127 silence) |

`flags` gains bit 2, `E2EE`: the reassembled frame is an SFrame ciphertext.

These travel in the clear on purpose. They are what a forwarder needs and
cannot read once the payload is encrypted: the dominant speaker comes from
`level`, the layer choice from `layer` and the keyframe bit.

## Control

Payload type 0, one datagram, one kind byte and a small JSON object. JSON
because control is a few messages a second and has to be readable in
`tcpdump -X`; media, thousands a second, is binary.

| kind | | |
| --- | --- | --- |
| `JOIN` | c→s | `{"token","pub"}` — repeated every 400 ms until welcomed |
| `WELCOME` | s→c | `{"src","call","ch","e2ee","gen"}` |
| `PEER` | s→c | `{"src","id","handle","name","color","pub","muted","cam_off"}`, one per participant |
| `ROSTER` | s→c | `{"gen","srcs":[…],"speaker"}`, on every change and every second |
| `STATE` | c→s | `{"muted","cam_off"}`, every 500 ms; doubles as the keepalive (6 s of silence and you are dropped) |
| `LEAVE` | c→s | sent three times |
| `KEYFRAME` | c→s `{"src"}` / s→c `{"layer"}` | a receiver's PLI, turned by the SFU into a request for the layer that receiver is actually getting |
| `FEEDBACK` | c→s | `{"loss","kbps","cap"}`, every 500 ms |
| `KEY` | c→s `{"to","kid","sealed"}` / s→c `{"from","kid","sealed"}` | a sealed SFrame base key, relayed |
| `SPEAKER` | s→c | `{"src"}` |
| `TIER` | s→c | `{"tier":"high"\|"low"\|"audio","est"}` |
| `ERROR` | s→c | `{"code","msg"}`: `bad_token`, `token_expired`, `bad_key`, `room_full`, `kicked` |

Every control message fits one datagram, which is why the roster is one `PEER`
per person plus a list of who is current, rather than one message.

## Simulcast and bandwidth

Every sender runs two encoders and publishes both:

| layer | | measured |
| --- | --- | --- |
| 0 | 640x360 @ 30 fps, H.264 300 kbit/s | 285-304 kbit/s |
| 1 | 320x180 @ 15 fps, H.264 90 kbit/s | 85-90 kbit/s |

Per receiver the SFU forwards one layer of every sender, or none:

| tier | forwards | needs (per other sender, with audio and overhead) |
| --- | --- | --- |
| high | layer 0 | 375 kbit/s |
| low | layer 1 — a quarter of the pixels, **half the frame rate** | 160 kbit/s |
| audio | no video | 45 kbit/s |

H.264 baseline has no temporal layers, so frames cannot be dropped from a
layer without breaking the ones that reference them; the frame-rate drop is
the low layer itself, which is encoded at 15 fps.

The choice runs on the receiver's own reports (`FEEDBACK`: percentage of
expected packets missing, by sequence number per stream, and the received
rate), loss-based in the way libwebrtc's loss controller is: under loss, what
did arrive is close to what the link carries, so the estimate drops to it;
while the reports are clean the estimate creeps up, and an upgrade is tried
only after three clean reports and an exponentially backed-off probe interval
(2 s doubling to 20 s), so a link that cannot carry `high` does not flap.
Reports from the first 1.5 s after a join are ignored: that is every sender's
first keyframe at once, and says more about the start than about the link.

A switch happens **only at a keyframe of the new layer**: until one arrives the
receiver keeps getting the old layer (no gap), and the SFU asks the sender for
one (rate-limited to four a second per sender layer). A downgrade to audio is
immediate. A receiver notices the switch from `layer` and resets its
reassembler and decoder.

Not done: TWCC-style delay-based estimation (this is loss-based only), last-N,
and pausing a layer nobody is receiving ("dynacast"): every sender always
sends both layers.

## Dominant speaker

From the `level` byte alone, so it works on encrypted audio: activity is
scored over a 200 ms and a 1 s window, and a challenger takes the floor only
when it beats the incumbent by a margin **for 400 ms**. That is a simplified
form of Volfin & Cohen's dominant speaker identification, which Jitsi
Videobridge and mediasoup run with a binomial speech model over three windows;
this keeps the shape and drops the statistics. A 120 ms interjection does not
steal the floor (asserted in the self-test).

## End-to-end encryption

**Status: implemented, with one stated limit.** Media is encrypted end to end;
the SFU forwards ciphertext and never holds a media key. What protects the
*public keys* is a safety code that people compare, not an authenticated
identity key — so an active attacker controlling the SFU or the gateway could
substitute keys, and the comparison is what detects it.

**Frames.** Each media frame is encrypted with SFrame (RFC 9605) before it is
fragmented, cipher suite `AES_128_GCM_SHA256_128` (0x0004): HKDF-SHA256 key and
salt derivation from a per-sender base key exactly as §4.4.2, nonce = salt XOR
counter, header plus metadata as AAD. The implementation is checked against
the RFC's own Appendix C vectors: all **289** header encodings of C.1 in both
directions, and the 0x0004 case of C.3 byte for byte. The metadata bound into
every frame is the payload type, the keyframe bit, the layer and the capture
timestamp — so the SFU can read all four but cannot change any of them (mark a
predicted frame as a keyframe, say) without the frame failing to open. Each
receiver keeps an SRTP-style 64-frame replay window per key.

**KID.** `src << 16 | generation`. A receiver that opens a frame knows whose key
opened it, and a frame whose KID names a different participant from the `src`
the SFU stamped is refused — so the SFU cannot relabel one person's media as
another's. A clear frame in an encrypted call is refused too, so the SFU cannot
inject media.

**Keys.** Each participant makes an X25519 keypair when it joins and discards
it when it leaves; the public key rides in `JOIN` and the SFU repeats it in
`PEER`. Each sender picks a random 16-byte base key per generation and seals it
to every other participant separately:

```
shared = X25519(my_secret, their_public)
wrap   = HKDF-SHA256(salt "palm-call-wrap-v1", shared,
                     info = sender_pub || recipient_pub || kid || call id)
blob   = nonce || ChaCha20-Poly1305(wrap, nonce, aad = kid || call id, base_key)
```

The SFU relays `blob` (and stamps who it came from); binding both public keys,
the KID and the call into the derivation means a blob cannot be replayed into
another call, generation or recipient. Keys are resent every second, because
this is UDP.

**Rotation.** A sender starts a new generation whenever the set of people in
the room changes — anyone joins or leaves, or is kicked — and seals it only to
the people now there. So someone who left cannot read what is said after, and
someone who joined never had the key to what was said before. A new key is
used for encryption 300 ms after it is sent, so receivers have it first, and a
superseded key still decrypts for 2 s at the receivers, for frames in flight.
The cost is visible in the measurements: 13-19 frames per stream at the start
of the call arrive before their key (`no key` below), about half a second.

**Safety code.** Every participant hashes the sorted list of `(identity id,
public key)` for everyone in the call, itself included, with SHA-256, and
shows five groups of five digits in the header and the People panel. Every
participant computes the same code from the same roster; a substituted key at
any participant makes the codes differ. In every run below, the three codes
were identical.

**What this is not, and the upgrade.** It is not MLS. The group key schedule
is per-sender keys sealed pairwise, which is O(n²) blobs per rotation — fine
for the rooms of 16 the SFU allows, poor for hundreds. Public keys are not
bound to anything enrolled in the account, which is why the safety code
exists. The upgrade path is the one the research points at: device keys
enrolled in the account and signed, then MLS (RFC 9420) with those as
credentials and SFrame keyed from the MLS exporter per sender, as Discord's
DAVE and Webex do; `libdave` ships a C API that could sit behind the same
`pcp` seam. The SFrame layer here would not change.

Chat is a different matter and is not end-to-end encrypted: the gateway
stores messages in Postgres and searches them. That is the documented
trade-off in `cloud/docs/chat-calls.md`.

## Screen sharing

`--share-screen --allow-screen` replaces the camera with the screen. A loop of
`grim` writes one PPM per capture into ffmpeg's `image2pipe`, stamped with the
wall clock and resampled to the call's rate, into the same encoder a camera
uses — so simulcast, SFrame and the SFU do not know the difference. It needs
its own flag, like a camera needs `--allow-real-devices`.

It works on a compositor with **wlr-screencopy** (sway, Hyprland, any wlroots
one), and it was tested on one: `cloud/rtc/sfu/screenshare.sh` starts a
private headless sway with a terminal on it, Bob shares that screen into a
call, and Alice's window, rendered offscreen, shows it in speaker view
(`shots/sfu-screen-share-dark.png`).

It does **not** work under Palmframe's own window manager today: `apps/wm`
implements no screen-capture protocol, neither wlr-screencopy nor
`ext-image-copy-capture-v1`, so there is nothing for a capture tool to ask.
That is the wm's gap to close (plus a portal for the permission prompt), and
the source here is ready for it.

## Echo cancellation

Not implemented in this app, deliberately. The realistic path is PipeWire's
`module-echo-cancel`, which runs WebRTC's AEC3 (`libspa-aec-webrtc.so`, which
is installed on this machine) between a virtual source and a virtual sink.
`--echo-cancel` makes the real-device path record from `echo-cancel-source` and
play into `echo-cancel-sink`; the synthetic sources are untouched, and nothing
changes unless the module is loaded, which belongs in Palmframe's PipeWire
configuration. It is not loaded here, and no real microphone was opened to
test it — the self-test asserts the command lines only. In-process AEC3 would
mean linking webrtc-audio-processing (C++ only) behind a C shim; speexdsp's
echo canceller is C but clearly worse with speakers and double talk.

## Measured

Three headless participants on loopback, synthetic camera and a scheduled
synthetic talker each (Alice 0-4 s, Bob 4-8 s, Carol 8-12 s, repeating every
12 s on one shared clock), playing into a paced null sink, end-to-end
encrypted, 20 s. `cloud/rtc/sfu/demo3.sh OUTDIR 20`:

| receiver ← sender | audio capture→received | max | jitter (RFC 3550) | capture→played | video frames (L0) | capture→decoded | lost | no key |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| alice ← bob | 2.99 ms | 6.3 | 1.03 ms | 36.5 ms | 587 | 7.45 ms | 0 | 17 |
| alice ← carol | 2.27 ms | 8.1 | 0.59 ms | 44.6 ms | 587 | 6.93 ms | 0 | 15 |
| bob ← carol | 2.48 ms | 11.1 | 0.58 ms | 39.5 ms | 587 | 7.06 ms | 0 | 15 |
| bob ← alice | 3.30 ms | 6.4 | 1.18 ms | 33.4 ms | 587 | 8.06 ms | 0 | 16 |
| carol ← bob | 2.61 ms | 7.4 | 0.35 ms | 34.9 ms | 587 | 7.25 ms | 0 | 17 |
| carol ← alice | 2.74 ms | 9.6 | 0.43 ms | 35.3 ms | 587 | 8.00 ms | 0 | 16 |

Every figure is a subtraction on one `CLOCK_MONOTONIC_RAW`, through the SFU
and through SFrame both ways. Capture→received includes up to 4 ms of the
headless loop's tick; capture→played adds the 40 ms jitter-buffer target.
Each sender sent 594 L0 frames (~300 kbit/s), 298 L1 frames (~90 kbit/s) and
996 audio frames; the SFU forwarded 11,610 datagrams for 7,007 received. The
safety code was the same at all three.

Dominant speaker, against the schedule:

| turn begins | SFU names | lag |
| --- | --- | --- |
| alice, 0 s | alice | +0.69 s |
| bob, 4 s | bob | +0.67 s |
| carol, 8 s | carol | +0.71 s |
| alice, 12 s | alice | +0.68 s |
| bob, 16 s | bob | +0.66 s |

The lag is the 400 ms hold plus the short window filling; no false switch in
any run.

**A constrained receiver.** The same call with Carol's downlink emulated at
400 kbit/s (`demo3.sh OUTDIR 20 400`; a token bucket with a 250 ms burst on
what she receives — what it drops is real loss to everything downstream):

- t=1.5 s (end of warm-up): Carol → **low**, estimate 363 kbit/s from 14.9 %
  loss. From then on she receives layer 1 from both senders: 268 + 267 L1
  frames against 35 + 26 L0 frames from before the switch, 427 KB of L1 and
  161 KB of L0 forwarded to her.
- t=18.1 s: a probe up to **high** (estimate 859), refused by the link within
  half a second: back to **low** at 18.6 s, and the next probe backs off.
- Alice and Bob stay on high throughout; nobody else is affected.

At 150 kbit/s (`demo3.sh OUTDIR 20 150`): Carol → **audio** at 1.9 s (estimate
129 kbit/s, 39.8 % loss), receives 984 and 982 of 985 audio frames from the
others and no video; one probe to low at 14 s falls back at 14.5 s.

## Running it

```sh
B=/path/to/bin
odin build cloud/rtc/sfu -out:$B/palm-sfu.bin -o:speed
odin build apps/call -collection:palmy=… -collection:shadcn=… -collection:kit=… -out:$B/call.bin -o:speed

$B/palm-sfu.bin --selftest                       # 100 checks
$B/call.bin --self-test                          # 430 checks
bash cloud/rtc/sfu/demo3.sh /tmp/out 20          # the measurement above
bash cloud/rtc/sfu/demo3.sh /tmp/out 20 400      # Carol on a 400 kbit/s downlink
bash cloud/rtc/sfu/shots.sh /tmp/shots dark      # screenshots, offscreen
bash cloud/rtc/sfu/screenshare.sh /tmp/share     # screen share on a private sway

# by hand:
echo some-long-random-secret > secret
$B/palm-sfu.bin --secret-file secret --port 47900 --stats
T=$($B/palm-sfu.bin --mint-token --secret-file secret --call c1 --id u1 --handle alice --name Alice)
$B/call.bin --sfu 127.0.0.1:47900 --join-token "$T"
```

In a real deployment the token comes from the chat gateway's `call_join`, and
`palm-sfu` is started with `--gateway` so membership changes reach running
calls.

**Deployment, not done.** `palm-sfu` binds 127.0.0.1 unless told otherwise. A
public deployment needs a public bind (it is one UDP port; with ICE-lite-style
latching it would get through most NATs), a TURN relay or a TCP/TLS-443
fallback for networks that block UDP, and the token secret managed as a
secret. None of that is built. There is also no recording: the schema has the
metadata table, and a recorder would be a participant that holds keys — which
is a product decision before it is code.

Screenshots: `shots/sfu-grid-dark.png`, `shots/sfu-grid-light.png`,
`shots/sfu-speaker-dark.png`, `shots/sfu-speaker-people-light.png` (with the
People and encryption panel), `shots/sfu-screen-share-dark.png`.
