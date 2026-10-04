# The film

A two-minute short about the toolkit, on the homepage. Cut from footage that
already existed, to a score written here.

```sh
bash film/build.sh          # scan, score, stills, cut, encode
bash film/build.sh score    # just the music
bash film/build.sh stills   # just chapter four's rendered frames
bash film/build.sh cut      # just the edit
bash film/build.sh encode   # just the two encodes, the poster and the captions
```

Outputs land in `site/public/film/`: `palmframe.webm` (VP9/Opus),
`palmframe.mp4` (H.264/AAC), `palmframe-poster.jpg` and `film.vtt`.
Intermediates go in `film/.work/`, which is not committed.

## The one rule

**Every cut lands on a beat.** Not approximately — exactly. The film runs at
24 fps and the score at 144 BPM, so a beat is

    24 fps x 60 / 144 BPM = 10 frames

which is a whole number. `shots.json` places and measures every shot in beats
and `build.py` multiplies by ten; `score/compose.py` reads the same tempo out
of the same file and lays the bars on the same grid. There is no place where a
time in seconds is chosen by eye, and nothing can drift, because neither side
knows what a second is.

The clearest demonstration of this is the sequence in chapter two. The parity
suite's comparison reel holds each of its 182 cases for 1.4 s; `setpts`
resamples it by `0.41667 / 1.4` so a case lasts exactly one beat, and then the
case changes *are* the beats.

## The files

| file | what it is |
| --- | --- |
| `shots.json` | **the source**. Every shot, in beats, with its footage, its text and its caption. Changing the film means changing this. |
| `build.py` | renders each shot on its own, concatenates them, applies the grade |
| `encode.sh` | the two encodes, the poster frame, the caption track |
| `build.sh` | all of it, in order |
| `score/midi.py` | a Standard MIDI writer, by hand: chunks, variable-length delta times, meta events |
| `score/compose.py` | the composition — two original cues, emitted as four stems |
| `score/render.sh` | fluidsynth, then the surf signal chain in ffmpeg |
| `score/*.mid` | the generated MIDI, committed so the score is inspectable without running anything |
| `tools/rtlcheck/` | an Odin program that renders chapter four's two frames through palmy's own text path |
| `tools/captions.py` | WebVTT, from the captions in `shots.json` |
| `tools/scan-identity.sh` | the safety gate: frames out, OCR, grep |
| `SOURCES.md` | every clip used, every clip rejected, and why |

## The score

Original, written for this film: an instrumental surf-rock theme in E minor
and a spaghetti-western cue in A minor. Genre, not quotation — nothing here is
modelled on an existing recording. The MIDI is written byte by byte by
`score/midi.py` because there is no `mido` on this machine and a repository
that hand-rolls ZIP, PDF and the Wayland wire protocol can manage one more
container format.

The sound is the chain, not the patch. General MIDI's clean electric guitar
goes through `tremolo` at 5.6 Hz and two staggered `aecho`s, which is a spring
reverb tank described in ffmpeg filters; the drums get a short room only,
because a kit through a reverb tank turns to soup.

## Chapter four draws itself

The fourth chapter is about what palmy's text path does and does not do with
bidirectional text, and a claim like that has no business being a card. So its
two frames are rendered **by that text path**, by `tools/rtlcheck`: Hebrew
reordered, Arabic joined and a line holding both directions on one frame; the
vowel marks that GPOS would attach and the Devanagari that is not shaped at
all on the next, with a crash zoom into the evidence.

That makes the chapter self-checking. If shaping regresses, the frame the film
holds regresses with it, because `build.sh` re-renders it on every build
rather than keeping a committed PNG.

## Safety

Read `SOURCES.md` before adding a clip. The short version: this goes to a
public CDN, several of the demo takes contain the user's real home directory,
real wifi networks, real hardware and in one case real photographs of real
people, and the OCR grep caught only some of them. Look at the frames.
