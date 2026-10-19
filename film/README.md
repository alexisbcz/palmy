# The film

Two minutes and thirteen seconds about the toolkit, on the homepage.
Everything on screen is the window manager or an application; the score was
written for it.

The spine is the window manager — a Wayland compositor that is itself a palmy
client, with four applications running inside it, launched, cascaded, moved,
resized and maximised. Then sixteen more applications, four beats each; then
six of them introduced by name; then what the toolkit still cannot do.

```sh
bash film/build.sh          # scan, score, capture, cut, encode
bash film/build.sh score    # just the music
bash film/build.sh capture  # just the three recordings
bash film/build.sh cut      # just the edit
bash film/build.sh encode   # just the two encodes, the poster and the captions
```

Outputs land in `site/public/film/`: `palmy.webm` (VP9/Opus),
`palmy.mp4` (H.264/AAC), `palmy-poster.jpg` and `film.vtt`.
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

The clearest demonstration is the application montage in chapter two: sixteen
programs, four beats each, every cut on a downbeat, derived rather than
dialled in.

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
| `tools/capture/` | the recording sandbox, the steps files, and the document chapter four films |
| `tools/captions.py` | WebVTT, from the captions in `shots.json` |
| `tools/scan-identity.sh` | the safety gate: frames out, OCR, grep |
| `tools/scan-used.py` | the windows the shot list takes, so the gate scans what ships rather than whole clips |
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

## The score grows with the film

`score/compose.py` does not contain a bar map. It reads `shots.json` and
derives one: the chapter cards are the section boundaries, the shot holding
the time-jump card is where the band drops out, the last chapter card is where
the western cue takes over, and the beats the band hits are wherever the
`intro` shots put their freeze frames. Widen the edit by thirty seconds and
the score is thirty seconds longer, in the same key, without a number being
typed twice.

## Chapter four films its own evidence

The chapter claims the toolkit still gets things wrong about right-to-left
text, so it shows them rather than asserting them: the word processor, opening
a document in Arabic, Devanagari and English. The Arabic is joined — the
letters take their cursive forms — and the crash zoom lands on the vowel marks
sitting on the advance instead of on the letter, with the unshaped Devanagari
underneath.

`build.sh` re-records that take on every build. If shaping regresses, the
frame the film holds regresses with it.

## Safety

Read `SOURCES.md` before adding a clip. The short version: this goes to a
public CDN, several of the demo takes contain the user's real home directory,
real wifi networks, real hardware and in one case real photographs of real
people, and the OCR grep caught only some of them. Look at the frames.
