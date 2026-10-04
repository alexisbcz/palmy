"""Standard MIDI files, written by hand.

There is no `mido` on this machine and no `numpy`, and taking a dependency for
the sake of a hundred-odd bytes of framing would be out of keeping with a
repository that hand-rolls ZIP, PDF and the Wayland wire protocol. SMF is a
small format: two chunk types, a handful of meta events, and one piece of
genuine fiddliness in the delta times.

The format, in full, as far as this file needs it:

  * **MThd** — `4D 54 68 64`, a big-endian length of 6, then `format`,
    `ntrks` and `division`, each a 16-bit big-endian word. Format 1 means
    "several tracks, one timeline"; division is ticks per quarter note.
  * **MTrk** — `4D 54 72 6B`, a big-endian byte length, then the events. The
    length has to be written *after* the events exist, which is why a track is
    serialised into a buffer first and framed second.
  * **delta times** — every event is preceded by a variable-length quantity:
    seven bits per byte, most significant first, with bit 7 set on every byte
    but the last. The trap is that a delta of 0 is a single `00` byte rather
    than nothing at all, and a track whose first event is at tick 0 still
    needs it.
  * **running status** is not used here. It saves bytes and costs clarity, and
    a MIDI file that fluidsynth reads once is not worth the saving.

The two meta events that matter for a film score are the tempo
(`FF 51 03`, microseconds per quarter note) and the time signature
(`FF 58 04`). A track that ends without `FF 2F 00` is malformed, and
fluidsynth will read it anyway, which is exactly how that bug survives.
"""

import struct

TICKS_PER_QUARTER = 480
DRUM_CHANNEL = 9


def vlq(n: int) -> bytes:
    """A variable-length quantity: seven bits per byte, high bit as continue."""
    if n < 0:
        raise ValueError("delta times cannot be negative")
    out = bytearray([n & 0x7F])
    n >>= 7
    while n:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    return bytes(reversed(out))


class Track:
    """Events collected at absolute ticks, sorted and delta-encoded on output.

    Collecting absolute ticks and sorting at the end is what lets a composer
    write one voice at a time without tracking a cursor. The sort key carries
    an `order` field so that a note-off at tick T always precedes a note-on at
    tick T: emitting them the other way round makes a synth retrigger and then
    immediately silence the new note, which sounds like a dropped note and
    reads like a bug in the composition.
    """

    def __init__(self, name: str = ""):
        self.events: list[tuple[int, int, bytes]] = []
        if name:
            n = name.encode()
            self.events.append((0, -2, b"\xff\x03" + vlq(len(n)) + n))

    def _add(self, tick: int, order: int, payload: bytes) -> None:
        self.events.append((int(round(tick)), order, payload))

    # -- meta -------------------------------------------------------------
    def tempo(self, tick: int, bpm: float) -> None:
        us = int(round(60_000_000 / bpm))
        self._add(tick, -3, b"\xff\x51\x03" + us.to_bytes(3, "big"))

    def time_signature(self, tick: int, num: int, den_pow2: int) -> None:
        self._add(tick, -3, bytes([0xFF, 0x58, 0x04, num, den_pow2, 24, 8]))

    # -- channel ----------------------------------------------------------
    def program(self, tick: int, channel: int, program: int) -> None:
        self._add(tick, -1, bytes([0xC0 | channel, program & 0x7F]))

    def control(self, tick: int, channel: int, cc: int, value: int) -> None:
        self._add(tick, -1, bytes([0xB0 | channel, cc & 0x7F, value & 0x7F]))

    def pitch_bend(self, tick: int, channel: int, value: int) -> None:
        v = max(0, min(16383, value + 8192))
        self._add(tick, -1, bytes([0xE0 | channel, v & 0x7F, (v >> 7) & 0x7F]))

    def note(self, tick, channel, pitch, duration, velocity) -> None:
        p = max(0, min(127, int(pitch)))
        v = max(1, min(127, int(velocity)))
        self._add(tick, 1, bytes([0x90 | channel, p, v]))
        self._add(tick + duration, 0, bytes([0x80 | channel, p, 0]))

    # -- output -----------------------------------------------------------
    def serialize(self) -> bytes:
        body = bytearray()
        last = 0
        for tick, _, payload in sorted(self.events, key=lambda e: (e[0], e[1])):
            body += vlq(tick - last)
            body += payload
            last = tick
        body += vlq(0) + b"\xff\x2f\x00"
        return b"MTrk" + struct.pack(">I", len(body)) + bytes(body)


def write(path: str, tracks: list[Track], division: int = TICKS_PER_QUARTER) -> int:
    live = [t for t in tracks if t.events]
    data = b"MThd" + struct.pack(">IHHH", 6, 1, len(live), division)
    for t in live:
        data += t.serialize()
    with open(path, "wb") as f:
        f.write(data)
    return len(data)
