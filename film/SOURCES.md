# Source footage, and what the scan found

Everything on screen in this film is the window manager or an application.
Most of it is cut from demo takes the applications already had; three takes
are made by `film/build.sh capture`, because the committed footage could not
serve them.

Before a clip may appear in `shots.json` it has to appear here, with the
result of `film/tools/scan-identity.sh` against it. That script samples frames
across a clip, OCRs each one with tesseract, and greps the text for anything
that identifies the machine or its owner. **It is necessary and not
sufficient.** Four of the clips rejected below passed the grep and were caught
only by looking at a contact sheet, so every clip used here was also reviewed
by eye across its whole length.

## Recorded for the film

| clip | what it is |
| --- | --- |
| `film/.work/capture/wm.mp4` | the window manager with **calc, maps, sheets and calendar** running inside it — launched, cascaded, cycled, moved, resized, maximised |
| `film/.work/capture/wm2.mp4` | the same, with **editor, reader, emoji and archive** |
| `film/.work/capture/rtl.mp4` | the word processor opening `film/tools/capture/rtl.md`, in Arabic, Devanagari and English |

These are not committed. `film/build.sh capture` re-records them inside
`film/tools/capture/sandbox.sh`, which takes the techniques
`site/scripts/shots-apps.sh` established for the documentation screenshots —
a private UTS namespace so the hostname is `palmy`, a private PID namespace,
`HOME` and the XDG directories redirected — and adds a mount namespace.

Re-recording rather than committing is deliberate for the third one: chapter
four claims the toolkit still gets some things wrong about right-to-left text,
and re-shooting the evidence on every build means that if shaping regresses,
the frame the film holds regresses with it.

### Two things about the window-manager take that are not obvious

**`apps/wm` spawns a fixed table of five programs by absolute path**, four
examples out of `./bin` and `/usr/bin/foot`. That table lives in the window
manager's source, which this film does not own. So the sandbox binds other
binaries to those paths: the window manager is told nothing and lies about
nothing, it execs the path it always execs. `/usr/bin/foot` is bound to
`/bin/true`, so the one key that opens a terminal cannot.

**The consequence is that the window manager's own labels name the slot, not
the binary.** Its toast says "launched counter" while a calculator appears,
and its status bar carries a permanent legend reading "F1 counter  F2
gallery  F3 todo  F4 foot  F5 pixels". Two answers, both recorded in the
sources rather than buried:

* **both are covered.** `shots.json` carries a `mask` over the right-hand end
  of the bar on every window-manager shot and `build.py` draws it. The status
  bar was read back out of the finished cut to confirm it: what survives is
  "palmy wm · 4 windows · 4 clients · 61 fps", which is true;
* and the take is structured so it would be safe anyway. The toast lasts
  three seconds (`wall_now() - s.status_at < 3.0`), `wm.txt` leaves four
  after the last launch, and the desktop footage is taken from there on.

No frame in this film shows a label naming a program other than the one on
screen.

### Why chapter four's document is single words

The first version of that document had multi-word lines — `שלום עולם`,
`السلام عليكم`, `הקוד palmy נכתב`. The word processor renders them with the
**inter-word spaces missing**, so `שלום עולם` comes out as `עולםשלום`.

It is not the synthetic keyboard: `docs --export-png` on a markdown file
reproduces it with no keyboard involved. It is not `palmy/font.odin` either —
the same strings drawn straight through `p.text` keep their spaces. So it is
somewhere in the word processor's own run or line model, where Latin spaces
survive and a space inside a right-to-left run does not.

That is a real defect and it is reported rather than filmed. A frame showing
it, captioned "reordered", would read as the toolkit dropping spaces, and this
film cannot afford a caption that is wrong about what the viewer is looking
at. So the document uses single words, where the question does not arise and
all three claims — joining, the unattached marks, the unshaped matra — are
still visible.

## Used, from committed demo takes

`apps/{ai,audio,calc,calendar,docs,editor,emoji,maps,notes,pickdemo,reader,sheets,shop,torrent,vault,video}/demo.mp4`
— sixteen applications. Each was scanned across its whole length and reviewed
as a contact sheet, and `film/build.sh scan` then re-scans **the exact window
the shot list takes**, sixteen frames per window, through
`film/tools/scan-used.py`. That distinction earns its keep: `docs` has the
real home directory on screen around fifty seconds in, and the film takes four
seconds at forty-four and two at fifty-five. Scanning the clip says HIT and
tells you nothing about whether the film is safe.

The content is synthetic throughout: a generated novel, a fictional city
called Marisport, a demo vault under `/tmp`, a torrent on loopback, "Regional
sales, 2026".

With the window manager that is **seventeen of the forty applications**, which
is what the film says on screen.

## Rejected

Twenty-three applications are not in this film. Not one of them is excluded
for being unfinished — every rejection below is about what the *recording*
caught, not about the program.

| clip | what is in it |
| --- | --- |
| `files` | **the real home directory** — real folder names, a real Downloads listing, a media library. Passed the grep; the contact sheet did not. |
| `image` | **real photographs of real people**, out of the real Downloads folder. Passed the grep. |
| `money` | a French bank statement: a salary line, named direct debits, a balance. Passed the grep, rejected on sight. |
| `photoshop` | the desktop's own crash notifications, and a panel of real account usage. Passed the grep. |
| `launcher` | the real wifi SSID in the status bar, which names a household |
| `network` | every neighbouring network by name and signal, which is a geolocation fix |
| `bluetooth` | real device names and MAC addresses |
| `mixer` | the real audio hardware, including the webcam's microphone and its input meter |
| `call` | the webcam's name in its device list. Its *video* is synthetic — SMPTE bars, and it says so on screen — but the hardware is still named. |
| `archive`, `captions`, `chat`, `clipboard`, `greeter`, `mail`, `ocr`, `power`, `screenshot`, `slides`, `sysmon`, `videoedit` | OCR hits on `alex`, `/home/`, the hostname, or the desktop's crash toasts |
| `chatbot` | not a palmy program at all: a headless daemon that imports neither palmy nor shadcn, whose demo films **`chat`'s** window. Labelling that footage "chatbot" would caption one program with another's name. |
| `kit`, `tools`, `mailcore`, `prose` | no window by construction — two are libraries, one is headless, one was being written while this was cut. None of them gets an invented frame. |

Several of the rejected ones *do* appear in the film, running inside the
window manager, because the sandbox removes the reason they were rejected:
`editor`, `reader`, `emoji` and `archive` are in the second take.

## Camera and microphone

**No frame of this film is camera footage and no audio in it was recorded by a
microphone.** Three independent reasons:

- none of the committed source clips has an audio stream at all — `ffprobe`
  reports one video stream and nothing else for every one of them, so there is
  no path by which microphone audio could reach the mix. The only audio is
  `film/score/`, synthesised by fluidsynth from MIDI written by
  `film/score/compose.py`;
- the recordings made for the film are screen captures of a headless
  compositor with no input devices and no media sources;
- the one clip that names the webcam, `call`, is rejected above.

## The scan of the finished film

The gate that matters is the output, not the inputs. Frames are extracted from
the graded cut at 3 fps, OCRed, and grepped against the same pattern set, and
every distinct word found is read by hand. The result is recorded in the
report for each cut; it has been zero hits for every cut shipped.
