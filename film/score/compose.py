#!/usr/bin/env python3
"""The score for the film, composed here and emitted as Standard MIDI.

Everything in this file is original. It is written in a genre -- instrumental
surf rock, and a spaghetti-western cue for the slow chapter -- and a genre is
not a composition. No progression, melody or rhythm here is quoted from or
modelled on any existing recording, because this goes on a public website and
"it only sounds a bit like it" is not a defence.

Two cues:

  A. **PALMFRAME SURF**, E minor, 144 BPM. Eight bars, i-III-IV-i-VI-VII-i-V
     (Em G A Em C D Em B7). The A major in bar three is the borrowed dorian
     fourth that the genre lives on, and the B7 at the end is a real dominant
     so the loop pulls rather than merely repeats. A second eight -- theme B,
     Am Am Em Em C B7 Em Em -- holds longer notes so the lead can be
     tremolo-picked against it.

  B. **THE LINE**, A minor, half-time against the same 144 BPM clock, so the
     cuts stay on the grid while the music halves its pulse. Whistle over
     sustained guitar, a trumpet answering two bars later, woodblock on the
     backbeat. Am F G Am Dm E7 Am Am.

The arrangement is written out as four separate MIDI files rather than one,
because the surf sound is a signal chain and not a patch: the lead has to go
through tremolo and a long echo on its own, and a drum kit through the same
chain turns to soup. film/score/render.sh renders each stem with fluidsynth
and processes them separately before mixing.

The tempo and the bar grid come from film/shots.json, so the music and the
cut list cannot drift apart: at 144 BPM and 24 fps a beat is exactly ten
frames, and every cut in the film lands on one.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from midi import Track, write, TICKS_PER_QUARTER as TPQ, DRUM_CHANNEL  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SHOTS = json.load(open(os.path.join(ROOT, "film", "shots.json")))
BPM = SHOTS["tempo_bpm"]
BEATS_PER_BAR = SHOTS["beats_per_bar"]

BAR = TPQ * BEATS_PER_BAR
BEAT = TPQ
EIGHTH = TPQ // 2
SIXTEENTH = TPQ // 4

# -- the harmony -------------------------------------------------------------
# Chord -> (root pitch class, the triad or seventh above it, in semitones).
CHORDS = {
    "Em": (4, [0, 3, 7]),
    "G":  (7, [0, 4, 7]),
    "A":  (9, [0, 4, 7]),
    "C":  (0, [0, 4, 7]),
    "D":  (2, [0, 4, 7]),
    "B7": (11, [0, 4, 7, 10]),
    "Am": (9, [0, 3, 7]),
    "Dm": (2, [0, 3, 7]),
    "F":  (5, [0, 4, 7]),
    "E7": (4, [0, 4, 7, 10]),
}

THEME_A_CHORDS = ["Em", "G", "A", "Em", "C", "D", "Em", "B7"]
THEME_B_CHORDS = ["Am", "Am", "Em", "Em", "C", "B7", "Em", "Em"]
WESTERN_CHORDS = ["Am", "F", "G", "Am", "Dm", "E7", "Am", "Am"]

# -- the melodies ------------------------------------------------------------
# Theme A: eight eighth notes a bar, arpeggios that climb through each chord
# and fall back. Written as MIDI note numbers; 76 is E5.
THEME_A_LEAD = [
    [76, 71, 76, 79, 83, 79, 76, 71],   # Em
    [79, 74, 79, 83, 86, 83, 79, 74],   # G
    [81, 76, 81, 85, 88, 85, 81, 76],   # A  -- the C# is the dorian colour
    [76, 79, 83, 79, 76, 74, 71, 67],   # Em
    [72, 79, 84, 79, 76, 72, 67, 72],   # C
    [74, 81, 86, 81, 78, 74, 69, 74],   # D
    [76, 83, 88, 83, 79, 76, 71, 76],   # Em
    [71, 75, 78, 81, 83, 81, 78, 75],   # B7 -- D# leading back to E
]

# Theme B: longer notes, so the lead can sit on them, with a run out of bar 8.
THEME_B_LEAD = [
    [(81, BEAT), (84, BEAT), (88, BEAT), (84, BEAT)],
    [(83, BEAT * 2), (81, BEAT * 2)],
    [(76, BEAT), (79, BEAT), (83, BEAT), (79, BEAT)],
    [(78, BEAT * 2), (76, BEAT * 2)],
    [(79, BEAT), (76, BEAT), (72, BEAT), (76, BEAT)],
    [(78, BEAT), (75, BEAT), (71, BEAT), (75, BEAT)],
    [(76, BEAT * 4)],
    [(76, EIGHTH), (78, EIGHTH), (79, EIGHTH), (81, EIGHTH),
     (83, EIGHTH), (84, EIGHTH), (86, EIGHTH), (88, EIGHTH)],
]

# The western cue: a whistle that holds, and a trumpet that answers it.
WESTERN_WHISTLE = [
    [(81, BEAT * 3), (84, BEAT)],
    [(81, BEAT * 4)],
    [(83, BEAT * 2), (79, BEAT * 2)],
    [(81, BEAT * 4)],
    [(86, BEAT * 2), (84, BEAT * 2)],
    [(83, BEAT * 2), (80, BEAT * 2)],
    [(81, BEAT * 4)],
    [(76, BEAT * 4)],
]
WESTERN_TRUMPET = {
    1: [(69, BEAT), (72, BEAT), (69, BEAT * 2)],
    3: [(72, BEAT), (69, BEAT), (67, BEAT * 2)],
    5: [(71, BEAT), (68, BEAT), (64, BEAT * 2)],
    7: [(69, BEAT * 4)],
}

# -- General MIDI programs ---------------------------------------------------
GM_CLEAN_GUITAR = 27    # the lead and the rhythm both, before any processing
GM_FINGER_BASS = 33
GM_WHISTLE = 78
GM_TRUMPET = 56
GM_TREMOLO_STRINGS = 44

# The drum map, by GM note number.
KICK, SNARE, HAT, OPEN_HAT = 36, 38, 42, 46
CRASH, RIDE, WOODBLOCK = 49, 51, 76
LOW_TOM, MID_TOM, HIGH_TOM, FLOOR_TOM = 45, 47, 50, 41


def bar(n: int) -> int:
    return n * BAR


# ---------------------------------------------------------------------------
# The sections, in bars. These match film/shots.json beat for beat: a section
# boundary here is a cut there.
# ---------------------------------------------------------------------------
COLD_OPEN = (0, 8)       # the parity triptych
TITLE = (8, 10)          # PALMFRAME
STOP = (10, 12)          # TWO DAYS EARLIER -- the music drops out
CH1 = (12, 25)           # NO TOOLKIT
CH2 = (25, 38)           # THE INSTRUMENT
CH3 = (38, 51)           # THE CAST
CH4 = (51, 60)           # WHAT IT CANNOT DO YET -- the western cue
CRAWL = (60, 70)         # the numbers
END_BAR = 70

# Beats on which a character introduction freezes. The band hits these.
FREEZE_BEATS = [161, 169, 177, 185, 193, 201]

# Bars that play the surf band at all, as (first, last_exclusive, theme).
SURF = [
    (0, 8, "A"), (8, 10, "TITLE"), (12, 13, "PICKUP"),
    (13, 21, "A"), (21, 25, "B4"),
    (25, 26, "PICKUP"), (26, 34, "B"), (34, 38, "A4"),
    (38, 39, "PICKUP"), (39, 47, "A"), (47, 51, "B4"),
    (60, 68, "A"), (68, 70, "OUT"),
]


def theme_bars(kind):
    """The eight-bar themes, and the four-bar halves used to fill a chapter."""
    if kind == "A":
        return list(zip(THEME_A_CHORDS, THEME_A_LEAD))
    if kind == "B":
        return list(zip(THEME_B_CHORDS, THEME_B_LEAD))
    if kind == "A4":
        return list(zip(THEME_A_CHORDS[4:], THEME_A_LEAD[4:]))
    if kind == "B4":
        return list(zip(THEME_B_CHORDS[:4], THEME_B_LEAD[:4]))
    return []


# ---------------------------------------------------------------------------
# Lead guitar
# ---------------------------------------------------------------------------
def build_lead() -> Track:
    t = Track("lead guitar")
    t.program(0, 0, GM_CLEAN_GUITAR)
    t.control(0, 0, 7, 100)
    t.control(0, 0, 10, 54)       # a shade left of centre
    t.control(0, 0, 91, 127)      # the synth's own reverb, under the echo

    for first, last, kind in SURF:
        bars = theme_bars(kind)
        if kind == "TITLE":
            # One sustained chord over the title card, picked, left to ring.
            for i, p in enumerate([64, 71, 76, 79, 83]):
                t.note(bar(first) + i * SIXTEENTH, 0, p, BAR * 2, 96 - i * 4)
            continue
        if kind == "PICKUP":
            # A four-note run into the chapter, the last one on the downbeat
            # of the next bar so the card lands with it.
            for i, p in enumerate([71, 74, 76, 79]):
                t.note(bar(last) - BEAT * (4 - i), 0, p, BEAT, 86 + i * 6)
            continue
        if kind == "OUT":
            # The ending: a rising figure, then the tonic held out.
            run = [64, 67, 71, 76, 79, 83, 88]
            for i, p in enumerate(run):
                t.note(bar(first) + i * EIGHTH, 0, p, EIGHTH, 100)
            t.note(bar(first) + len(run) * EIGHTH, 0, 88, BAR + BEAT * 2, 112)
            t.note(bar(first) + len(run) * EIGHTH, 0, 83, BAR + BEAT * 2, 100)
            t.note(bar(first) + len(run) * EIGHTH, 0, 76, BAR + BEAT * 2, 96)
            continue

        for n, (_chord, line) in enumerate(bars):
            b = bar(first + n)
            if n >= last - first:
                break
            if isinstance(line[0], tuple):
                at = b
                for pitch, dur in line:
                    t.note(at, 0, pitch, int(dur * 0.92), 100)
                    at += dur
            else:
                for i, pitch in enumerate(line):
                    # Surf picking accents the downbeat of every pair.
                    vel = 112 if i % 2 == 0 else 92
                    t.note(b + i * EIGHTH, 0, pitch, EIGHTH - 20, vel)
    return t


# ---------------------------------------------------------------------------
# Rhythm guitar and bass
# ---------------------------------------------------------------------------
def build_rhythm() -> Track:
    t = Track("rhythm and bass")
    t.program(0, 1, GM_CLEAN_GUITAR)
    t.control(0, 1, 7, 74)
    t.control(0, 1, 10, 84)       # the rhythm sits right
    t.control(0, 1, 91, 80)
    t.program(0, 2, GM_FINGER_BASS)
    t.control(0, 2, 7, 102)
    t.control(0, 2, 10, 64)

    for first, last, kind in SURF:
        if kind == "TITLE":
            root, ivals = CHORDS["Em"]
            for s in ivals:
                t.note(bar(first), 1, 52 + ((root + s - 4) % 12), BAR * 2, 72)
            t.note(bar(first), 2, 28, BAR * 2, 104)
            continue
        if kind in ("PICKUP", "OUT"):
            if kind == "OUT":
                root, ivals = CHORDS["Em"]
                for s in ivals:
                    t.note(bar(first) + BEAT * 4, 1, 52 + ((root + s - 4) % 12), BAR + BEAT * 2, 78)
                t.note(bar(first) + BEAT * 4, 2, 28, BAR + BEAT * 2, 108)
            continue

        bars = theme_bars(kind)
        for n, (chord, _line) in enumerate(bars):
            if n >= last - first:
                break
            b = bar(first + n)
            root, ivals = CHORDS[chord]

            # Rhythm: offbeat stabs, which is what keeps a surf track moving
            # without a second lead line fighting the first.
            voicing = [52 + ((root + s - 4) % 12) for s in ivals]
            for beat_i in range(BEATS_PER_BAR):
                at = b + beat_i * BEAT + EIGHTH
                for p in voicing:
                    t.note(at, 1, p, EIGHTH - 30, 68 if beat_i % 2 else 76)

            # Bass: a walking eighth-note figure, root fifth octave fifth.
            low = 28 + ((root - 4) % 12)
            walk = [low, low + 7, low + 12, low + 7, low, low + 7, low + 12, low + 10]
            for i, p in enumerate(walk):
                t.note(b + i * EIGHTH, 2, p, EIGHTH - 15, 104 if i % 2 == 0 else 88)
    return t


# ---------------------------------------------------------------------------
# Drums
# ---------------------------------------------------------------------------
def build_drums() -> Track:
    t = Track("drums")
    t.control(0, DRUM_CHANNEL, 7, 106)
    t.control(0, DRUM_CHANNEL, 91, 64)
    d = DRUM_CHANNEL

    playing = set()
    for first, last, kind in SURF:
        if kind in ("PICKUP",):
            # A tom roll into the chapter card. Six sixteenths, rising.
            roll = [FLOOR_TOM, FLOOR_TOM, LOW_TOM, LOW_TOM, MID_TOM, HIGH_TOM]
            for i, p in enumerate(roll):
                t.note(bar(last) - SIXTEENTH * (6 - i), d, p, SIXTEENTH, 80 + i * 8)
            continue
        if kind == "TITLE":
            t.note(bar(first), d, CRASH, BEAT * 4, 118)
            t.note(bar(first), d, KICK, BEAT, 112)
            continue
        if kind == "OUT":
            for i in range(6):
                t.note(bar(first) + BEAT * 4 + i * SIXTEENTH, d,
                       [FLOOR_TOM, LOW_TOM, LOW_TOM, MID_TOM, HIGH_TOM, HIGH_TOM][i],
                       SIXTEENTH, 90 + i * 6)
            t.note(bar(first) + BEAT * 4 + 6 * SIXTEENTH, d, CRASH, BEAT * 4, 124)
            t.note(bar(first) + BEAT * 4 + 6 * SIXTEENTH, d, KICK, BEAT, 120)
            continue
        playing.update(range(first, last))

    tom_driven = set(range(0, 8)) | set(range(39, 51))
    for b_i in sorted(playing):
        b = bar(b_i)
        t.note(b, d, CRASH, BEAT * 2, 104) if b_i in (0, 13, 26, 39, 60) else None
        for beat_i in range(BEATS_PER_BAR):
            at = b + beat_i * BEAT
            if beat_i in (0, 2):
                t.note(at, d, KICK, BEAT, 110)
            if beat_i == 2:
                t.note(at + EIGHTH, d, KICK, EIGHTH, 92)
            if beat_i in (1, 3):
                t.note(at, d, SNARE, BEAT, 112)
            if b_i in tom_driven:
                # The tom-driven feel: floor tom on the eighths under the
                # backbeat, which is the sound the genre is actually built on.
                t.note(at, d, FLOOR_TOM, EIGHTH, 86 if beat_i % 2 == 0 else 72)
                t.note(at + EIGHTH, d, LOW_TOM, EIGHTH, 70)
            else:
                t.note(at, d, HAT, EIGHTH, 86)
                t.note(at + EIGHTH, d, HAT, EIGHTH, 66)

    # The band hits every freeze frame in the character introductions.
    for beat_abs in FREEZE_BEATS:
        at = beat_abs * BEAT
        t.note(at, d, CRASH, BEAT * 2, 122)
        t.note(at, d, SNARE, BEAT, 120)
        t.note(at, d, KICK, BEAT, 118)

    # The western chapter keeps a woodblock on the backbeat at half time.
    for b_i in range(CH4[0] + 1, CH4[1]):
        t.note(bar(b_i) + BEAT * 2, d, WOODBLOCK, SIXTEENTH, 74)
    return t


# ---------------------------------------------------------------------------
# The western cue
# ---------------------------------------------------------------------------
def build_western() -> Track:
    t = Track("the line")
    t.program(0, 3, GM_WHISTLE)
    t.control(0, 3, 7, 80)
    t.control(0, 3, 10, 58)
    t.control(0, 3, 91, 127)
    t.program(0, 4, GM_TRUMPET)
    t.control(0, 4, 7, 64)
    t.control(0, 4, 10, 76)
    t.control(0, 4, 91, 110)
    t.program(0, 5, GM_CLEAN_GUITAR)
    t.control(0, 5, 7, 60)
    t.control(0, 5, 10, 40)
    t.program(0, 6, GM_TREMOLO_STRINGS)
    t.control(0, 6, 7, 40)
    t.control(0, 6, 91, 127)
    t.program(0, 7, GM_FINGER_BASS)
    t.control(0, 7, 7, 74)

    first = CH4[0] + 1          # bar 51 is the chapter card; the cue starts at 52
    for n, chord in enumerate(WESTERN_CHORDS):
        b = bar(first + n)
        root, ivals = CHORDS[chord]

        # Whistle, holding.
        at = b
        for pitch, dur in WESTERN_WHISTLE[n]:
            t.note(at, 3, pitch, int(dur * 0.95), 92)
            at += dur

        # Trumpet, answering in the odd bars.
        if n in WESTERN_TRUMPET:
            at = b + BEAT
            for pitch, dur in WESTERN_TRUMPET[n]:
                t.note(at, 4, pitch, int(dur * 0.9), 84)
                at += dur

        # Guitar, arpeggiating the chord slowly -- the twang.
        voicing = [57 + ((root + s - 9) % 12) for s in ivals]
        for i, p in enumerate(voicing + [voicing[0] + 12]):
            t.note(b + i * BEAT, 5, p, BEAT * 2, 78)

        # Strings and bass, holding the bar.
        for s in ivals:
            t.note(b, 6, 69 + ((root + s - 9) % 12), BAR, 54)
        t.note(b, 7, 33 + ((root - 9) % 12), BAR, 92)
    return t


def main():
    out = os.path.join(ROOT, "film", "score")
    meta = Track("palmframe")
    meta.time_signature(0, BEATS_PER_BAR, 2)
    meta.tempo(0, BPM)
    # A silent marker on the last bar line keeps every stem the same length,
    # so fluidsynth does not truncate one of them early and shift the mix.
    meta.note(bar(END_BAR), 15, 36, BEAT, 1)
    meta.control(0, 15, 7, 0)

    stems = {
        "lead": build_lead(),
        "rhythm": build_rhythm(),
        "drums": build_drums(),
        "western": build_western(),
    }
    for name, track in stems.items():
        path = os.path.join(out, f"{name}.mid")
        n = write(path, [meta, track])
        print(f"{name:9s} {n:6d} bytes  {len(track.events):5d} events")
    print(f"{END_BAR} bars at {BPM} BPM = {END_BAR * BEATS_PER_BAR * 60 / BPM:.3f} s")


if __name__ == "__main__":
    main()
