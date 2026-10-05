#!/usr/bin/env python3
"""Print `clip@from-to` for exactly the footage film/shots.json uses.

Scanning a whole demo take is the wrong question. `apps/docs/demo.mp4` has
`/home/alex/` on screen somewhere around fifty seconds in, and the film takes
four seconds at forty-four and two at fifty-five; scanning the clip says HIT
and tells you nothing about whether the film is safe. Scanning the windows
says whether the film is safe.

So this derives the windows from the shot list, with a margin on each end, and
film/build.sh feeds them to scan-identity.sh. A shot that moves is re-scanned
where it moved to, and a clip nobody uses any more stops being checked.
"""
import json, os

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SPEC = json.load(open(os.path.join(ROOT, "film", "shots.json")))
SEC = 60.0 / SPEC["tempo_bpm"]
MARGIN = 0.75

# One window per shot, not one per clip. Merging them would span the gap
# between two shots of the same take -- which for `docs` is exactly where the
# leak is -- and report a hit on footage the film never touches.
seen = set()
for s in SPEC["shots"]:
    src = s.get("src")
    if not src:
        continue
    a = max(0.0, s["in"] - MARGIN)
    b = s["in"] + s["beats"] * SEC + MARGIN
    key = (src, round(a, 2), round(b, 2))
    if key in seen:
        continue
    seen.add(key)
    print(f"{os.path.join(ROOT, src)}@{a:.2f}-{b:.2f}")
