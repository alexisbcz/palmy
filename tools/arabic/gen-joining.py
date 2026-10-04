#!/usr/bin/env python3
"""Generate the Arabic joining and presentation-form tables for palmy/shape.odin.

    python3 tools/arabic/gen-joining.py            # print the generated block
    python3 tools/arabic/gen-joining.py --splice   # rewrite palmy/shape.odin in place

Two independent sources, both Unicode 16.0.0 on this machine:

  * Python's `unicodedata` supplies the *shaping* table. Every codepoint in
    Arabic Presentation Forms-A (U+FB50..U+FDFF) and Forms-B (U+FE70..U+FEFF)
    carries a compatibility decomposition tagged <isolated>, <initial>,
    <medial> or <final>, which says exactly which base letter it is a form of.
    Inverting those decompositions *is* the shaping table -- nothing is typed
    by hand, and a letter can only be shaped into a form Unicode encodes.

  * libfribidi supplies the joining types (`fribidi_get_joining_type`, which is
    ArabicShaping.txt compiled into a table). palmy does not link fribidi; this
    generator does, and only to produce the table that gets committed.

The two are cross-checked against each other: a letter that Unicode gives an
initial or medial form to must be dual-joining in fribidi, a letter with only a
final form must be right-joining, and fribidi's transparent class must agree
with unicodedata's Mn/Me/Cf categories. A disagreement is a hard error.
"""

import ctypes
import os
import sys
import unicodedata

# --- fribidi joining types -------------------------------------------------
# fribidi-joining-types.h: the type is a mask.
M_JOINS_PREV = 0x01  # "joins right" in fribidi's naming: joins the character before it
M_JOINS_NEXT = 0x02  # "joins left": joins the character after it
M_SHAPES = 0x04
M_TRANSPARENT = 0x08
M_IGNORED = 0x10

fb = ctypes.CDLL("libfribidi.so.0")
fb.fribidi_get_joining_type.restype = ctypes.c_uint
fb.fribidi_get_joining_type.argtypes = [ctypes.c_uint32]
FRIBIDI_UNICODE = ctypes.c_char_p(
    ctypes.cast(fb.fribidi_unicode_version, ctypes.POINTER(ctypes.c_char_p))[0]
).value.decode()


def joining_type(cp):
    """Return one of U R L D C T, from fribidi's compiled ArabicShaping data."""
    m = fb.fribidi_get_joining_type(cp)
    if m & M_TRANSPARENT:
        return "T"
    if m & M_SHAPES:
        if m & M_JOINS_PREV and m & M_JOINS_NEXT:
            return "D"
        if m & M_JOINS_PREV:
            return "R"
        if m & M_JOINS_NEXT:
            return "L"
        return "U"
    if m & M_JOINS_PREV and m & M_JOINS_NEXT:
        return "C"
    return "U"


# The ranges the table covers. Outside them every codepoint is non-joining,
# which is what breaks a joining run at a space, a digit or a Latin letter.
#
#   0600..08FF  Arabic, Syriac, Arabic Supplement, Thaana, NKo, Samaritan,
#               Mandaic, Syriac Supplement, Arabic Extended-A/B/C
#   200C..206F  the format controls: ZWNJ (non-joining), ZWJ (join-causing),
#               and the Cf characters that are transparent
#   FB50..FEFF  Presentation Forms-A and -B, plus the variation selectors at
#               FE00..FE0F, which are transparent and must not break a join
COVERED = [(0x0600, 0x08FF), (0x200C, 0x206F), (0xFB50, 0xFEFF)]

# ArabicShaping.txt gives Joining_Type=T to every unlisted Mn/Me/Cf character.
# These are the Cf characters it lists explicitly instead, so the cross-check
# below has to know them: the prepended concatenation marks, the two zero-width
# joiners, and the bidi isolate controls. Anything else that disagrees with
# unicodedata's category is a bug in this generator or a Unicode version skew.
NOT_TRANSPARENT = {
    0x0600: "U", 0x0601: "U", 0x0602: "U", 0x0603: "U", 0x0604: "U", 0x0605: "U",
    0x06DD: "U", 0x0890: "U", 0x0891: "U", 0x08E2: "U",
    0x200C: "U",  # ZWNJ breaks a join
    0x200D: "C",  # ZWJ causes one
    0x2066: "U", 0x2067: "U", 0x2068: "U", 0x2069: "U",
}

FORM_TAGS = {"<isolated>": 0, "<final>": 1, "<initial>": 2, "<medial>": 3}
FORM_NAMES = ["Isolated", "Final", "Initial", "Medial"]
ALEFS = {0x0622, 0x0623, 0x0625, 0x0627}  # alef madda, hamza above, hamza below, plain


def build():
    forms = {}  # base -> [isol, fina, init, medi]
    ligs = {}  # (lam, alef) -> [isol, fina]
    for cp in range(0xFB50, 0x10000):
        d = unicodedata.decomposition(chr(cp))
        if not d:
            continue
        parts = d.split()
        if parts[0] not in FORM_TAGS:
            continue
        slot = FORM_TAGS[parts[0]]
        bases = [int(x, 16) for x in parts[1:]]
        if len(bases) == 1:
            forms.setdefault(bases[0], [0, 0, 0, 0])[slot] = cp
        elif len(bases) == 2 and bases[0] == 0x0644 and bases[1] in ALEFS:
            # The four encoded lam-alef ligatures. Unicode gives each one an
            # isolated and a final form and nothing else, which is right: the
            # alef cannot join to what follows, so the pair never goes medial.
            if slot in (0, 1):
                ligs.setdefault(tuple(bases), [0, 0])[slot] = cp
    return forms, ligs


def check(forms):
    """Cross-check the two sources. Returns the number of assertions made."""
    n = 0
    for base, f in sorted(forms.items()):
        jt = joining_type(base)
        n += 1
        if f[2] or f[3]:
            assert jt == "D", f"U+{base:04X} has an initial/medial form but fribidi says {jt}"
        elif f[1]:
            assert jt in ("R", "D"), f"U+{base:04X} has a final form but fribidi says {jt}"
        else:
            assert jt in ("U", "R", "D"), f"U+{base:04X} {jt}"
        n += 1
        assert any(f), f"U+{base:04X} has no forms at all"
    # fribidi's transparent class must be exactly unicodedata's Mn/Me/Cf,
    # minus ZWJ (join-causing) and ZWNJ (non-joining), over the covered ranges.
    for lo, hi in COVERED:
        for cp in range(lo, hi + 1):
            cat = unicodedata.category(chr(cp))
            if cat == "Cn":  # unassigned: fribidi may class it either way
                continue
            jt = joining_type(cp)
            n += 1
            if cp in NOT_TRANSPARENT:
                assert jt == NOT_TRANSPARENT[cp], f"U+{cp:04X} {jt}"
                continue
            if cat in ("Mn", "Me", "Cf"):
                assert jt == "T", f"U+{cp:04X} is {cat} but fribidi says {jt}"
            else:
                assert jt != "T", f"U+{cp:04X} is {cat} but fribidi says transparent"
    return n


def ranges():
    """Collapse the covered codepoints into runs of equal joining type."""
    out = []
    for lo, hi in COVERED:
        start, cur = lo, joining_type(lo)
        for cp in range(lo + 1, hi + 2):
            jt = joining_type(cp) if cp <= hi else None
            if jt != cur:
                if cur != "U":  # non-joining is the default, so it needs no row
                    out.append((start, cp - 1, cur))
                start, cur = cp, jt
    return out


ODIN_JT = {"U": ".Non_Joining", "R": ".Right", "L": ".Left", "D": ".Dual", "C": ".Causing", "T": ".Transparent"}


def emit(forms, ligs, rows, nchecks):
    L = []
    w = L.append
    w("// BEGIN GENERATED -- do not edit by hand.")
    w("//")
    w("// tools/arabic/gen-joining.py, from Unicode %s (python unicodedata) and" % unicodedata.unidata_version)
    w("// libfribidi's ArabicShaping tables (Unicode %s). Regenerate with" % FRIBIDI_UNICODE)
    w("//")
    w("//\tpython3 tools/arabic/gen-joining.py --splice")
    w("//")
    w("// %d joining ranges, %d shapable letters, %d lam-alef ligatures." % (len(rows), len(forms), len(ligs)))
    w("// The generator cross-checks the two sources against each other with %d" % nchecks)
    w("// assertions before emitting anything.")
    w("")
    w("@(private)")
    w("ARABIC_JOINING := [?]Joining_Range {")
    for lo, hi, jt in rows:
        w("\t{0x%04x, 0x%04x, %s}," % (lo, hi, ODIN_JT[jt]))
    w("}")
    w("")
    w("// One row per letter Unicode encodes a presentation form for, sorted by")
    w("// codepoint: {base, {isolated, final, initial, medial}}. A zero means that")
    w("// form is not encoded, and shaping falls back towards the isolated form.")
    w("@(private)")
    w("ARABIC_FORMS := [?]Arabic_Letter {")
    for base, f in sorted(forms.items()):
        name = unicodedata.name(chr(base), "?")
        w(
            "\t{0x%04x, {0x%04x, 0x%04x, 0x%04x, 0x%04x}}, // %s"
            % (base, f[0], f[1], f[2], f[3], name)
        )
    w("}")
    w("")
    w("// The span of the letter table, so a string with no Arabic in it costs one")
    w("// comparison per rune and no search.")
    w("ARABIC_FORMS_LO :: rune(0x%04x)" % min(forms))
    w("ARABIC_FORMS_HI :: rune(0x%04x)" % max(forms))
    w("")
    w("// lam + alef is a required ligature. These four pairs are the only ones")
    w("// Unicode encodes a form for, and they are the only ones palmy forms.")
    w("@(private)")
    w("ARABIC_LAM_ALEF := [?]Lam_Alef {")
    for (lam, alef), f in sorted(ligs.items()):
        w(
            "\t{0x%04x, {0x%04x, 0x%04x}}, // lam + %s"
            % (alef, f[0], f[1], unicodedata.name(chr(alef), "?"))
        )
    w("}")
    w("")
    w("// END GENERATED")
    return "\n".join(L)


def main():
    forms, ligs = build()
    n = check(forms)
    rows = ranges()
    block = emit(forms, ligs, rows, n)
    if "--splice" in sys.argv:
        path = os.path.join(os.path.dirname(__file__), "..", "..", "palmy", "shape.odin")
        src = open(path).read()
        a = src.index("// BEGIN GENERATED")
        b = src.index("// END GENERATED") + len("// END GENERATED")
        open(path, "w").write(src[:a] + block[block.index("// BEGIN GENERATED"):] + src[b:])
        print("spliced %d ranges, %d letters, %d ligatures into %s (%d cross-checks ok)"
              % (len(rows), len(forms), len(ligs), os.path.normpath(path), n), file=sys.stderr)
    else:
        print(block)
        print("# %d cross-check assertions passed" % n, file=sys.stderr)


main()
