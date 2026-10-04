#!/usr/bin/env python3
"""gen-bidi-table.py — emit palmy's Unicode bidi character tables.

palmy/bidi.odin implements UAX #9, which needs three pieces of Unicode data:
the Bidi_Class of every codepoint, the Bidi_Mirroring_Glyph pairs (rule L4),
and the Bidi_Paired_Bracket pairs (rule BD16). None of that is worth
hand-typing — it is 745 class ranges — and a hand-typed copy cannot be
reviewed or refreshed when Unicode moves. So it is generated here and spliced
into palmy/bidi.odin between two markers, which keeps the module one file and
makes a regeneration show up as an ordinary diff.

    python3 tools/bidi/gen-bidi-table.py            # rewrite palmy/bidi.odin
    python3 tools/bidi/gen-bidi-table.py --check     # exit 1 if stale
    python3 tools/bidi/gen-bidi-table.py --stdout    # print the region only

Sources, both Unicode 16.0.0 on this machine:

  * Python's `unicodedata.bidirectional()` for the class of every *assigned*
    codepoint. This is the primary source.
  * Perl's `unicore/To/{Bc,Bmg,Bpb,Bpt}.pl` for the rest: the DerivedBidiClass
    @missing defaults (unassigned codepoints in the Hebrew/Arabic/Thaana
    blocks default to R, AL or AN, not to L, and `unicodedata` reports an
    empty string for them), the mirroring glyphs and the bracket pairs, none
    of which `unicodedata` exposes as data. Where the two sources overlap —
    every assigned codepoint's class — the generator asserts they agree, so
    the Perl files cannot silently drift from the stated Unicode version.

fribidi is deliberately *not* a source here: it is the independent oracle the
tests compare against, and generating palmy's tables from it would make that
comparison circular. tests/bidi_test.odin checks the table against fribidi
anyway, codepoint by codepoint, via tools/bidi/gen-bidi-cases.py.
"""

import argparse
import os
import re
import sys
import unicodedata

UNICORE = "/usr/share/perl5/core_perl/unicore"
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TARGET = os.path.join(ROOT, "palmy", "bidi.odin")

BEGIN = "// ---- BEGIN GENERATED TABLES (tools/bidi/gen-bidi-table.py) ----"
END = "// ---- END GENERATED TABLES ----"

# The 23 Bidi_Class values, in the order palmy's Bidi_Class enum declares them.
CLASSES = [
    "L", "R", "AL", "EN", "ES", "ET", "AN", "CS", "NSM", "BN", "B", "S", "WS",
    "ON", "LRE", "RLE", "LRO", "RLO", "PDF", "LRI", "RLI", "FSI", "PDI",
]

MAX_CP = 0x110000


def perl_version() -> str:
    with open(os.path.join(UNICORE, "version")) as f:
        return f.read().strip()


def perl_invmap(name: str):
    """Parse one of Perl's unicore/To/*.pl inversion maps into (lo, hi, value)."""
    path = os.path.join(UNICORE, "To", name + ".pl")
    with open(path) as f:
        text = f.read()
    body = text.split("return <<'END';")[1].split("\nEND")[0]
    out = []
    for line in body.splitlines():
        if not line.strip():
            continue
        fields = line.split("\t")
        lo = int(fields[0], 16)
        hi = int(fields[1], 16) if fields[1].strip() else lo
        value = fields[2].strip() if len(fields) > 2 else ""
        out.append((lo, hi, value))
    return out


def bidi_classes():
    """One Bidi_Class per codepoint, unicodedata first, Perl for the gaps."""
    defaults = ["L"] * MAX_CP
    for lo, hi, cls in perl_invmap("Bc"):
        for cp in range(lo, hi + 1):
            defaults[cp] = cls

    classes = []
    for cp in range(MAX_CP):
        cls = unicodedata.bidirectional(chr(cp))
        if cls == "":
            # Unassigned, a surrogate, or a noncharacter: DerivedBidiClass
            # gives these a block-dependent default, which matters because
            # `0x0870` landing on L instead of AL would misorder real text.
            cls = defaults[cp]
        elif cls != defaults[cp]:
            raise SystemExit(
                "U+%04X: unicodedata says %s, Perl unicore says %s — the two "
                "sources are not the same Unicode version" % (cp, cls, defaults[cp])
            )
        if cls not in CLASSES:
            raise SystemExit("U+%04X: unknown Bidi_Class %r" % (cp, cls))
        classes.append(cls)
    return classes


def merge(classes):
    """Collapse to ranges, dropping the L runs: L is the table's default."""
    ranges = []
    cp = 0
    while cp < MAX_CP:
        cls = classes[cp]
        start = cp
        while cp + 1 < MAX_CP and classes[cp + 1] == cls:
            cp += 1
        if cls != "L":
            ranges.append((start, cp, cls))
        cp += 1
    return ranges


def mirror_pairs():
    pairs = []
    for lo, hi, value in perl_invmap("Bmg"):
        if not value:
            continue
        # Bmg maps single codepoints; a range would need a per-codepoint walk,
        # which the data never asks for, so refuse rather than guess.
        if lo != hi:
            raise SystemExit("U+%04X..U+%04X: unexpected Bmg range" % (lo, hi))
        if not unicodedata.mirrored(chr(lo)):
            raise SystemExit("U+%04X has a mirroring glyph but is not mirrored" % lo)
        pairs.append((lo, int(value, 16)))
    pairs.sort()
    return pairs


def bracket_pairs():
    kinds = {}
    for lo, hi, value in perl_invmap("Bpt"):
        for cp in range(lo, hi + 1):
            if value in ("o", "O", "c", "C"):
                kinds[cp] = value.upper()
    out = []
    for lo, hi, value in perl_invmap("Bpb"):
        if not value:
            continue
        if lo != hi:
            raise SystemExit("U+%04X..U+%04X: unexpected Bpb range" % (lo, hi))
        kind = kinds.get(lo)
        if kind is None:
            raise SystemExit("U+%04X has a paired bracket but no bracket type" % lo)
        out.append((lo, int(value, 16), kind))
    out.sort()
    return out


def bracket_canon(brackets):
    """BD16 matches brackets under canonical equivalence.

    U+2329 and U+3008 are canonically equivalent, so `⟨a〉` is a pair. The
    singleton canonical decompositions of the bracket characters are the whole
    of that equivalence in practice, so emit just those.
    """
    canon = []
    for cp, _paired, _kind in brackets:
        decomp = unicodedata.decomposition(chr(cp))
        if not decomp or decomp.startswith("<"):
            continue
        parts = decomp.split()
        if len(parts) != 1:
            continue
        canon.append((cp, int(parts[0], 16)))
    canon.sort()
    return canon


def emit(classes):
    ranges = merge(classes)
    mirrors = mirror_pairs()
    brackets = bracket_pairs()
    canon = bracket_canon(brackets)

    out = []
    w = out.append
    w(BEGIN)
    w("// Unicode %s. Regenerate with:" % unicodedata.unidata_version)
    w("//     python3 tools/bidi/gen-bidi-table.py")
    w("// Do not edit the lines below by hand.")
    w("")
    w("// BIDI_CLASS_RANGES holds every codepoint whose Bidi_Class is not L,")
    w("// as %d sorted, non-overlapping ranges; a codepoint found in none of" % len(ranges))
    w("// them is L, which covers the other %s codepoints." % f"{sum(1 for c in classes if c == 'L'):,}")
    w("@(private)")
    w("BIDI_CLASS_RANGES := [%d]Bidi_Class_Range{" % len(ranges))
    for lo, hi, cls in ranges:
        w("\t{0x%04X, 0x%04X, .%s}," % (lo, hi, cls))
    w("}")
    w("")
    w("// BIDI_MIRROR_PAIRS is Bidi_Mirroring_Glyph: rule L4 draws the first of")
    w("// each pair as the second when it falls in a right-to-left run.")
    w("@(private)")
    w("BIDI_MIRROR_PAIRS := [%d][2]rune{" % len(mirrors))
    for a, b in mirrors:
        w("\t{0x%04X, 0x%04X}," % (a, b))
    w("}")
    w("")
    w("// BIDI_BRACKETS is Bidi_Paired_Bracket plus Bidi_Paired_Bracket_Type,")
    w("// which rule BD16 uses to find the bracket pairs N0 then resolves.")
    w("@(private)")
    w("BIDI_BRACKETS := [%d]Bidi_Bracket{" % len(brackets))
    for cp, paired, kind in brackets:
        w("\t{0x%04X, 0x%04X, .%s}," % (cp, paired, "Open" if kind == "O" else "Close"))
    w("}")
    w("")
    w("// BIDI_BRACKET_CANON folds the canonically equivalent brackets together,")
    w("// so BD16 pairs U+2329 with U+3009 and U+3008 with U+232A.")
    w("@(private)")
    w("BIDI_BRACKET_CANON := [%d][2]rune{" % len(canon))
    for a, b in canon:
        w("\t{0x%04X, 0x%04X}," % (a, b))
    w("}")
    w(END)
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="exit 1 if the table in palmy/bidi.odin is stale")
    ap.add_argument("--stdout", action="store_true", help="print the generated region instead of splicing it")
    args = ap.parse_args()

    if perl_version() != unicodedata.unidata_version:
        raise SystemExit(
            "Perl unicore is Unicode %s but Python unicodedata is %s; refusing to "
            "mix two versions in one table" % (perl_version(), unicodedata.unidata_version)
        )

    region = emit(bidi_classes())

    if args.stdout:
        sys.stdout.write(region)
        return

    with open(TARGET) as f:
        src = f.read()
    pattern = re.compile(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n", re.S)
    if not pattern.search(src):
        raise SystemExit("%s has no generated-table markers" % TARGET)
    updated = pattern.sub(lambda _: region, src, count=1)

    if args.check:
        if updated != src:
            raise SystemExit("%s is stale — rerun tools/bidi/gen-bidi-table.py" % TARGET)
        print("palmy/bidi.odin tables are up to date (Unicode %s)" % unicodedata.unidata_version)
        return

    with open(TARGET, "w") as f:
        f.write(updated)
    print("palmy/bidi.odin: Unicode %s tables written" % unicodedata.unidata_version)


if __name__ == "__main__":
    main()
