#!/usr/bin/env python3
"""Cut the film from film/shots.json.

Every shot is rendered on its own into an intermediate at a high bitrate,
and the intermediates are concatenated and graded in one final pass. That is
slower than one enormous filtergraph and very much easier to debug: when a
shot is wrong you can look at that shot.

The one rule the whole edit hangs on is that **a cut lands on a beat**. No
time in this file is chosen by eye. A shot's position and length are given in
beats in shots.json, and

    frames_per_beat = fps * 60 / tempo = 24 * 60 / 144 = 10

turns them into frames. Because that is an integer, a cut is simultaneously
an exact frame boundary and an exact beat of the score, and the score is
generated from the same two numbers in film/score/compose.py.

Shot types:

  card        heavy condensed type on black. "Condensed" is not a font here:
              the card is drawn on a 1792-wide canvas and scaled to 1280,
              which squeezes the glyphs horizontally by 0.714 and leaves
              their height alone. The repository ships Geist and no condensed
              face, and squeezing the project's own typeface is a better
              answer than importing a different one.
  term        a terminal, with real command output, revealed line by line.
  clip        a segment of demo footage, cropped to fill.
  intro       a clip that freezes on its last frame while a name slams on.
  parity      a held frame of the parity comparison reel, by case name.
  parity-rip  the same reel resampled so one case lasts exactly one beat.
  crawl       the end crawl.
"""

import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FILM = os.path.join(ROOT, "film")
WORK = os.path.join(FILM, ".work")
SHOTS_DIR = os.path.join(WORK, "shots")
TEXT_DIR = os.path.join(WORK, "text")

SPEC = json.load(open(os.path.join(FILM, "shots.json")))
FPS = SPEC["fps"]
W, H = SPEC["width"], SPEC["height"]
BPM = SPEC["tempo_bpm"]
FRAMES_PER_BEAT = FPS * 60 / BPM
assert FRAMES_PER_BEAT == int(FRAMES_PER_BEAT), "tempo and fps must give whole frames per beat"
FRAMES_PER_BEAT = int(FRAMES_PER_BEAT)
SEC_PER_BEAT = 60.0 / BPM

# The condensed canvas: drawn this wide, scaled down to W.
CW = 1792

PAL = {k: "#" + v[2:] for k, v in SPEC["palette"].items()}
FONT = {k: (v if v.startswith("/") else os.path.join(ROOT, v))
        for k, v in SPEC["fonts"].items()}

# The parity comparison reel holds each case for exactly this long, in the
# alphabetical order the report lists them in. Verified by OCRing the label
# at six points across the reel against the index computed here.
PARITY_REEL = os.path.join(ROOT, "parity", "out", "video", "comparison.mp4")
CASE_SECONDS = 1.4


def parity_index():
    """case name -> (ordinal, seconds into the reel), from the parity report."""
    report = os.path.join(ROOT, "parity", "out", "report.md")
    names = []
    for line in open(report):
        m = re.match(r"^\| `([^`]+)` \| [0-9x]+ \| [0-9.]+ \|", line)
        if m:
            names.append(m.group(1))
    names.sort()
    return {n: (i, i * CASE_SECONDS) for i, n in enumerate(names)}


CASES = parity_index()


def run(args, **kw):
    r = subprocess.run(args, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.stderr.write(" ".join(args[:6]) + " ...\n" + r.stderr[-4000:] + "\n")
        raise SystemExit(f"ffmpeg failed ({r.returncode})")
    return r


_text_n = 0


def textfile(s: str) -> str:
    """drawtext's `text=` needs four levels of escaping; `textfile=` needs none."""
    global _text_n
    _text_n += 1
    p = os.path.join(TEXT_DIR, f"t{_text_n:04d}.txt")
    with open(p, "w") as f:
        f.write(s)
    return p


def dt(s, font, size, color, x, y, **kw):
    # expansion=none: drawtext otherwise reads % as the start of a
    # strftime-ish escape, and the crawl says "90.40%".
    bits = [f"fontfile={FONT[font]}", f"textfile={textfile(s)}",
            "expansion=none",
            f"fontsize={size}", f"fontcolor={color}", f"x={x}", f"y={y}"]
    for k, v in kw.items():
        bits.append(f"{k}={v}")
    return "drawtext=" + ":".join(bits)


def fill(src_w=None):
    """Scale to cover the frame and crop the middle out of what is left."""
    return (f"scale={W}:{H}:force_original_aspect_ratio=increase,"
            f"crop={W}:{H}")


def pad():
    return (f"scale={W}:{H}:force_original_aspect_ratio=decrease,"
            f"pad={W}:{H}:(ow-iw)/2:(oh-ih)/2:black")


def zoom_filter(z, frames, iw, ih, prescale=True):
    """A crash zoom, as a linear ramp between two magnifications.

    zoompan rescales from the frame it is given, so the source is doubled
    first: punching 3x into a 1280-wide frame and back out to 1280 otherwise
    shows the interpolation rather than the pixels. `prescale=False` is for a
    source that already carries the extra pixels -- the stills palmy renders
    for chapter four come out at 2560x1440 for exactly this reason.
    """
    a, b = z["from"], z["to"]
    cx, cy = z.get("cx", 0.5), z.get("cy", 0.5)
    expr = f"{a}+({b}-{a})*on/{max(frames - 1, 1)}"
    pre = f"scale={iw * 2}:{ih * 2}:flags=bicubic," if prescale else ""
    return (pre + f"zoompan=z='{expr}':d=1:fps={FPS}:s={W}x{H}"
            f":x='iw*{cx}-(iw/zoom)/2':y='ih*{cy}-(ih/zoom)/2'")


# ---------------------------------------------------------------------------
# Shot renderers. Each returns (inputs, filtergraph) for one shot.
# ---------------------------------------------------------------------------
def shot_card(s, dur, frames):
    lines = s["lines"]
    block = []
    total = 0
    for i, ln in enumerate(lines):
        gap = ln.get("gap", 0) if i else 0
        total += gap + int(ln["size"] * 1.12)
    y = (H - total) // 2
    badge_h = 0
    if s.get("badge"):
        badge_h = 86
        y -= badge_h // 2
    for i, ln in enumerate(lines):
        if i:
            y += ln.get("gap", 0)
        size = ln["size"]
        block.append(dt(ln["s"], "display", size, PAL[ln.get("color", "cream")],
                        "(w-text_w)/2", y, line_spacing=0))
        y += int(size * 1.12)
    if s.get("badge"):
        y += 30
        block.append(dt(s["badge"], "body", 38, "#0A0A0A", "(w-text_w)/2", y,
                        box=1, boxcolor=PAL["cream"], boxborderw="22|34|18|34"))
    graph = (f"color=c=black:s={CW}x{H}:d={dur}:r={FPS}[bg];"
             f"[bg]" + ",".join(block) + f",scale={W}:{H}:flags=bilinear[v]")
    return [], graph


def shot_term(s, dur, frames):
    """A terminal. The output is the real thing, pasted from a real run."""
    mono = FONT["mono"]
    x0, y0, lh, fs = 150, 170, 58, 40
    parts = [f"color=c=black:s={W}x{H}:d={dur}:r={FPS}[bg];[bg]"]
    f = [f"drawtext=fontfile={mono}:textfile={textfile(s['prompt'])}"
         f":fontsize={fs}:fontcolor={PAL['cream']}:x={x0}:y={y0}"]
    for i, line in enumerate(s["out"]):
        at = 0.55 + i * 0.16
        f.append(f"drawtext=fontfile={mono}:textfile={textfile('        ' + line)}"
                 f":expansion=none:fontsize={fs}:fontcolor={PAL['white']}:x={x0}:y={y0 + (i + 2) * lh}"
                 f":enable='gte(t,{at:.2f})'")
    cur_y = y0 + (len(s["out"]) + 3) * lh
    f.append(f"drawtext=fontfile={mono}:textfile={textfile('$ _')}"
             f":expansion=none:fontsize={fs}:fontcolor={PAL['cream']}:x={x0}:y={cur_y}"
             f":enable='lt(mod(t,0.9),0.5)*gte(t,{0.55 + len(s['out']) * 0.16:.2f})'")
    f.append(f"drawtext=fontfile={FONT['body']}"
             f":textfile={textfile('the whole dependency list of a palmy binary')}"
             f":expansion=none:fontsize=28:fontcolor={PAL['dim']}:x={x0}:y={H - 90}")
    graph = "".join(parts) + ",".join(f)
    if s.get("zoom"):
        graph += "," + zoom_filter(s["zoom"], frames, W, H)
    graph += "[v]"
    return [], graph


def shot_clip(s, dur, frames):
    src = os.path.join(ROOT, s["src"])
    ins = ["-ss", str(s["in"]), "-t", f"{dur + 0.4:.3f}", "-i", src]
    chain = [pad() if s.get("fit") == "pad" else fill()]
    if s.get("zoom"):
        chain.append(zoom_filter(s["zoom"], frames, W, H))
    chain.append(f"fps={FPS}")
    if s.get("label"):
        chain.append(dt(s["label"], "body", 30, PAL["cream"], 44, H - 76,
                        box=1, boxcolor="black@0.72", boxborderw="14|20|14|20"))
    return ins, f"[0:v]{','.join(chain)},trim=duration={dur},setpts=PTS-STARTPTS[v]"


def shot_intro(s, dur, frames):
    """Grindhouse: run, freeze, slam the name on."""
    src = os.path.join(ROOT, s["src"])
    hold = s["freeze"] * SEC_PER_BEAT
    live = dur - hold
    ins = ["-ss", str(s["in"]), "-t", f"{live + 0.4:.3f}", "-i", src]
    band = H - 230
    chain = [
        fill(), f"fps={FPS}",
        f"trim=duration={live:.4f}", "setpts=PTS-STARTPTS",
        f"tpad=stop_mode=clone:stop_duration={hold:.4f}",
        f"drawbox=x=0:y={band}:w={W}:h=230:color=black@0.80:t=fill"
        f":enable='gte(t,{live:.4f})'",
        dt(s["name"], "display", 76, PAL["cream"], 64, band + 38,
           enable=f"'gte(t,{live:.4f})'"),
        dt(s["stat"], "body", 34, PAL["white"], 64, band + 136,
           enable=f"'gte(t,{live:.4f})'"),
        # A single-frame white flash on the freeze, which is what sells it.
        f"drawbox=x=0:y=0:w={W}:h={H}:color=white@0.55:t=fill"
        f":enable='between(t,{live:.4f},{live + 1.0 / FPS:.4f})'",
    ]
    return ins, f"[0:v]{','.join(chain)}[v]"


def shot_still(s, dur, frames):
    """A still palmy rendered for the film, held or pushed into.

    Chapter four is about what the text renderer does and does not do with
    bidirectional text, so its frames are drawn by that renderer rather than
    asserted on a card: film/tools/rtlcheck writes them at 2560x1440, which is
    twice the output, so a crash zoom has real pixels to find.
    """
    src = os.path.join(WORK, s["src"])
    if not os.path.exists(src):
        raise SystemExit(f"{s['id']}: {src} missing -- run film/tools/rtlcheck/run.sh")
    ins = ["-loop", "1", "-framerate", str(FPS), "-t", f"{dur + 0.2:.3f}", "-i", src]
    chain = []
    if s.get("zoom"):
        chain.append(zoom_filter(s["zoom"], frames, W, H, prescale=False))
    else:
        chain.append(f"scale={W}:{H}:flags=bicubic")
    chain += [f"fps={FPS}", f"trim=duration={dur}", "setpts=PTS-STARTPTS"]
    return ins, f"[0:v]{','.join(chain)}[v]"


def shot_parity(s, dur, frames):
    _, t = CASES[s["case"]]
    ins = ["-ss", f"{t + 0.15:.3f}", "-t", f"{min(dur, CASE_SECONDS - 0.2) + 0.1:.3f}",
           "-i", PARITY_REEL]
    chain = [f"fps={FPS}", f"loop=loop=-1:size={frames}:start=0",
             f"trim=duration={dur}", "setpts=PTS-STARTPTS"]
    if s.get("zoom"):
        chain.append(zoom_filter(s["zoom"], frames, W, H))
    for col, x in zip(s.get("columns", []), [205, 613, 1021]):
        chain.append(dt(col, "body", 26, PAL["cream"], f"{x}-text_w/2", 118,
                        box=1, boxcolor="black@0.8", boxborderw="10|14|8|14"))
    for tx in s.get("text", []):
        at = tx.get("from", 0) * SEC_PER_BEAT
        chain.append(dt(tx["s"], "display", tx["size"], PAL[tx.get("color", "cream")],
                        "(w-text_w)/2", f"{int(H * tx['y'])}",
                        enable=f"'gte(t,{at:.3f})'"))
    return ins, f"[0:v]{','.join(chain)}[v]"


def shot_parity_rip(s, dur, frames):
    """One case per beat: resample the reel by 1.4 s / one beat."""
    start, t = CASES[s["case"]]
    n = s["count"]
    speed = SEC_PER_BEAT / CASE_SECONDS
    ins = ["-ss", f"{t:.3f}", "-t", f"{n * CASE_SECONDS + 0.2:.3f}", "-i", PARITY_REEL]
    chain = [f"setpts={speed:.8f}*PTS", f"fps={FPS}",
             f"trim=duration={dur}", "setpts=PTS-STARTPTS"]
    return ins, f"[0:v]{','.join(chain)}[v]"


def shot_crawl(s, dur, frames):
    rows = s["lines"]
    row_h = 66
    top = H - 140
    # The crawl does not run off the top: it comes to rest with the last
    # block -- the three lines about what is not in the film -- in the middle
    # of the frame, so the cut to the end card lands on something readable
    # rather than on black.
    travel = top + (len(rows) - 1) * row_h - 300
    items = []
    for i, (label, value) in enumerate(rows):
        y = f"{top + i * row_h}-{travel}*t/{dur:.4f}"
        if label and not value:
            items.append(dt(label, "display", 46, PAL["cream"], 150, y))
        elif label:
            items.append(dt(label, "body", 34, PAL["white"], 150, y))
            items.append(dt(value, "display", 40, PAL["cream"], f"{W - 150}-text_w", f"({y})-4"))
    graph = (f"color=c=black:s={W}x{H}:d={dur}:r={FPS}[bg];[bg]"
             + ",".join(items) + "[v]")
    return [], graph


RENDERERS = {
    "card": shot_card, "term": shot_term, "clip": shot_clip, "intro": shot_intro,
    "parity": shot_parity, "parity-rip": shot_parity_rip, "crawl": shot_crawl,
    "still": shot_still,
}


def render_shot(s):
    frames = s["beats"] * FRAMES_PER_BEAT
    dur = frames / FPS
    ins, graph = RENDERERS[s["type"]](s, dur, frames)
    out = os.path.join(SHOTS_DIR, f"{s['beat']:03d}-{s['id']}.mp4")
    run(["ffmpeg", "-nostdin", "-v", "error", "-y", *ins,
         "-filter_complex", graph, "-map", "[v]",
         "-frames:v", str(frames), "-r", str(FPS),
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "14",
         "-pix_fmt", "yuv420p", out])
    got = int(subprocess.run(
        ["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
         "-show_entries", "stream=nb_read_frames", "-of", "csv=p=0", out],
        capture_output=True, text=True).stdout.strip() or 0)
    if got != frames:
        raise SystemExit(f"{s['id']}: wanted {frames} frames, got {got}")
    return out, frames


GRADE = (
    # A bleached, warm print: lift the blacks a little, pull the blue tail
    # down so the whites go cream, and take a touch of saturation out.
    "curves=r='0/0.035 0.25/0.27 0.5/0.53 0.75/0.80 1/0.98'"
    ":g='0/0.030 0.5/0.50 1/0.965':b='0/0.055 0.5/0.465 1/0.915',"
    "eq=saturation=0.90:contrast=1.05,"
    "vignette=angle=PI/5.2,"
    "rgbashift=rh=-1:bh=1,"
    "noise=alls=5:allf=t+u"
)


def main():
    for d in (SHOTS_DIR, TEXT_DIR):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d, exist_ok=True)

    shots = sorted(SPEC["shots"], key=lambda s: s["beat"])
    at = 0
    parts = []
    for s in shots:
        if s["beat"] != at:
            raise SystemExit(f"{s['id']} starts at beat {s['beat']}, expected {at}")
        path, frames = render_shot(s)
        print(f"  {s['beat']:4d} +{s['beats']:3d}  {s['type']:11s} {s['id']}")
        parts.append(path)
        at += s["beats"]
    print(f"  {at} beats = {at * SEC_PER_BEAT:.3f} s")

    listing = os.path.join(WORK, "concat.txt")
    with open(listing, "w") as f:
        for p in parts:
            f.write(f"file '{p}'\n")
    silent = os.path.join(WORK, "cut.mp4")
    run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-f", "concat", "-safe", "0",
         "-i", listing, "-c", "copy", silent])

    graded = os.path.join(WORK, "graded.mp4")
    run(["ffmpeg", "-nostdin", "-v", "error", "-y", "-i", silent,
         "-vf", GRADE, "-c:v", "libx264", "-preset", "slow", "-crf", "16",
         "-pix_fmt", "yuv420p", graded])
    print(f"graded -> {graded}")


if __name__ == "__main__":
    main()
