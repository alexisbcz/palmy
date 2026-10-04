#!/usr/bin/env python3
"""Shape the corpus with harfbuzz and emit what palmy's shaper must agree with.

    python3 tools/arabic/hb-oracle.py --emit > tests/arabic_oracle.odin
    python3 tools/arabic/hb-oracle.py --compare out.txt [--fuzz N]

harfbuzz is the reference shaper, and it is used here as a test oracle only:
palmy links nothing but libc and libm, and harfbuzz appears in no palmy build.

WHAT CAN AND CANNOT BE COMPARED

harfbuzz applies the font's GSUB and hands back font-specific glyph ids, while
palmy substitutes Unicode presentation-form codepoints. Those are different
domains, so the comparison is deliberately narrow:

  * COMPARABLE -- the joining decision per letter. Every Noto Arabic face names
    its contextual glyphs `uni0633.medi`, `uni066E.init`, `uni0627.fina` and so
    on, so harfbuzz's output says, per input character, which positional form
    GSUB chose. That is exactly the decision palmy's shaper makes, and it is
    compared character by character.
  * COMPARABLE -- where a lam-alef ligature was formed, and whether it is the
    isolated or the final variant. The Noto faces realise it as a pair of
    `.rlig` glyphs rather than one ligature glyph, so this is read off the
    `rlig` suffix and off any input character harfbuzz produced no glyph for.
  * COMPARABLE -- total advance width, as a separate check: the sum of the
    advances harfbuzz's GSUB output carries against the sum of the advances of
    palmy's presentation-form codepoints, read from the same font.
  * NOT COMPARABLE -- glyph ids. `cmap` maps U+FE91 to a composed `uniFE91`
    glyph while GSUB produces a dotless skeleton plus a separate dot glyph;
    both draw the same mark on the page, from different glyphs.
  * NOT COMPARABLE -- glyph counts, for the same reason: these faces split
    letters into skeleton and dots, so harfbuzz returns more glyphs than there
    are characters, and two glyphs where palmy emits one lam-alef ligature.
"""

import ctypes
import os
import random
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.environ.get("ORACLE_FONT", "/usr/share/fonts/noto/NotoSansArabic-Regular.ttf")

hb = ctypes.CDLL("libharfbuzz.so.0")
_SIGS = [
    ("hb_blob_create_from_file", ctypes.c_void_p, [ctypes.c_char_p]),
    ("hb_face_create", ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_uint]),
    ("hb_font_create", ctypes.c_void_p, [ctypes.c_void_p]),
    ("hb_buffer_create", ctypes.c_void_p, []),
    ("hb_buffer_add_utf8", None, [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int, ctypes.c_uint, ctypes.c_int]),
    ("hb_buffer_guess_segment_properties", None, [ctypes.c_void_p]),
    ("hb_buffer_set_cluster_level", None, [ctypes.c_void_p, ctypes.c_uint]),
    ("hb_buffer_set_script", None, [ctypes.c_void_p, ctypes.c_uint]),
    ("hb_buffer_set_direction", None, [ctypes.c_void_p, ctypes.c_uint]),
    ("hb_buffer_set_language", None, [ctypes.c_void_p, ctypes.c_void_p]),
    ("hb_language_from_string", ctypes.c_void_p, [ctypes.c_char_p, ctypes.c_int]),
    ("hb_shape", None, [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint]),
    ("hb_buffer_get_length", ctypes.c_uint, [ctypes.c_void_p]),
    ("hb_buffer_get_glyph_infos", ctypes.c_void_p, [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]),
    ("hb_buffer_get_glyph_positions", ctypes.c_void_p, [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]),
    ("hb_buffer_destroy", None, [ctypes.c_void_p]),
    ("hb_font_get_nominal_glyph", ctypes.c_int, [ctypes.c_void_p, ctypes.c_uint, ctypes.POINTER(ctypes.c_uint)]),
    ("hb_font_get_glyph_h_advance", ctypes.c_int, [ctypes.c_void_p, ctypes.c_uint]),
    ("hb_font_get_glyph_name", ctypes.c_int, [ctypes.c_void_p, ctypes.c_uint, ctypes.c_char_p, ctypes.c_uint]),
    ("hb_version_string", ctypes.c_char_p, []),
]
for n, r, a in _SIGS:
    f = getattr(hb, n)
    f.restype, f.argtypes = r, a


HB_SCRIPT_ARABIC = 0x41726162  # 'Arab'
HB_DIRECTION_RTL = 5


class GlyphInfo(ctypes.Structure):
    _fields_ = [("codepoint", ctypes.c_uint), ("mask", ctypes.c_uint), ("cluster", ctypes.c_uint),
                ("var1", ctypes.c_uint), ("var2", ctypes.c_uint)]


class GlyphPos(ctypes.Structure):
    _fields_ = [("x_advance", ctypes.c_int), ("y_advance", ctypes.c_int),
                ("x_offset", ctypes.c_int), ("y_offset", ctypes.c_int), ("var", ctypes.c_uint)]


class Font:
    def __init__(self, path):
        blob = hb.hb_blob_create_from_file(path.encode())
        self.font = hb.hb_font_create(hb.hb_face_create(blob, 0))
        self._names = {}

    def name(self, gid):
        if gid not in self._names:
            buf = ctypes.create_string_buffer(256)
            ok = hb.hb_font_get_glyph_name(self.font, gid, buf, 256)
            self._names[gid] = buf.value.decode() if ok else ""
        return self._names[gid]

    def advance_of_codepoint(self, cp):
        g = ctypes.c_uint()
        if not hb.hb_font_get_nominal_glyph(self.font, cp, ctypes.byref(g)):
            return None
        return hb.hb_font_get_glyph_h_advance(self.font, g.value)

    def shape(self, text):
        buf = hb.hb_buffer_create()
        b = text.encode("utf-8")
        hb.hb_buffer_add_utf8(buf, b, len(b), 0, len(b))
        # The script and direction are forced rather than guessed. A real
        # engine segments a mixed line into runs and shapes the Arabic run as
        # Arabic; harfbuzz's guess looks at the first strong character, so a
        # line beginning "Hello" would otherwise be shaped as Latin and no
        # letter would join at all -- an artefact of the harness, not a
        # disagreement.
        hb.hb_buffer_set_script(buf, HB_SCRIPT_ARABIC)
        hb.hb_buffer_set_direction(buf, HB_DIRECTION_RTL)
        hb.hb_buffer_set_language(buf, hb.hb_language_from_string(b"ar", -1))
        hb.hb_buffer_set_cluster_level(buf, 1)  # monotone characters: one cluster per char
        hb.hb_shape(self.font, buf, None, 0)
        n = hb.hb_buffer_get_length(buf)
        c = ctypes.c_uint()
        gi = ctypes.cast(hb.hb_buffer_get_glyph_infos(buf, ctypes.byref(c)), ctypes.POINTER(GlyphInfo))
        gp = ctypes.cast(hb.hb_buffer_get_glyph_positions(buf, ctypes.byref(c)), ctypes.POINTER(GlyphPos))
        out = [(gi[i].codepoint, gi[i].cluster, gp[i].x_advance) for i in range(n)]
        hb.hb_buffer_destroy(buf)
        return out


# The shapable letters, derived from unicodedata exactly as the table generator
# derives them, so the oracle does not depend on palmy's own table.
SHAPABLE = set()
for cp in range(0xFB50, 0x10000):
    d = unicodedata.decomposition(chr(cp)).split()
    if d and d[0] in ("<isolated>", "<final>", "<initial>", "<medial>") and len(d[1:]) == 1:
        SHAPABLE.add(int(d[1], 16))
LAM = 0x0644
ALEFS = {0x0622, 0x0623, 0x0625, 0x0627}


def oracle_forms(font, text):
    """Per input character, the positional form harfbuzz chose.

    X isolated, I initial, M medial, F final, L final lam-alef ligature,
    J isolated lam-alef ligature, ~ a letter a ligature swallowed, . not an
    Arabic letter (a mark, a space, Latin, a digit, tatweel, hamza, ...).
    """
    glyphs = font.shape(text)
    by_cluster = {}
    for gid, cluster, _ in glyphs:
        by_cluster.setdefault(cluster, []).append(font.name(gid))

    codes = []
    for off, ch in ((off, ch) for off, ch in _offsets(text)):
        cp = ord(ch)
        if cp not in SHAPABLE:
            codes.append(".")
            continue
        names = by_cluster.get(off)
        if not names:
            # No glyph at all for a letter: a ligature swallowed it.
            codes.append("~")
            continue
        sfx = set()
        for nm in names:
            parts = nm.split(".")
            sfx.update(parts[1:])
        form = "I" if "init" in sfx else "M" if "medi" in sfx else "F" if "fina" in sfx else "X"
        if "rlig" in sfx and cp == LAM:
            codes.append("L" if form == "M" else "J")
        elif "rlig" in sfx and cp in ALEFS:
            codes.append("~")
        else:
            codes.append(form)
    return "".join(codes)


def _offsets(text):
    off = 0
    for ch in text:
        yield off, ch
        off += len(ch.encode("utf-8"))


def advance_sum(font, text, shaped_cps):
    """harfbuzz's total advance against the presentation forms' total advance."""
    hb_total = sum(a for _, _, a in font.shape(text))
    mine = 0
    for cp in shaped_cps:
        a = font.advance_of_codepoint(cp)
        if a is None:
            return hb_total, None
        mine += a
    return hb_total, mine


def read_corpus():
    cases = []
    for line in open(os.path.join(HERE, "corpus.txt"), encoding="utf-8").read().split("\n"):
        if line.startswith("#") or (line.strip() == "" and line != " "):
            continue
        cases.append("" if line == "~empty~" else line)
    return cases


# --- random Arabic strings, for the fuzz comparison ------------------------
ALPHABET = (
    [chr(c) for c in range(0x0621, 0x064B)]          # the basic alphabet
    + [chr(c) for c in (0x064B, 0x064E, 0x064F, 0x0650, 0x0651, 0x0652, 0x0670)]  # harakat
    + [chr(c) for c in (0x0640, 0x200C, 0x200D)]     # tatweel, ZWNJ, ZWJ
    + [chr(c) for c in (0x067E, 0x0686, 0x0698, 0x06A9, 0x06AF, 0x06CC, 0x0679)]  # Persian/Urdu
    + list(" ,.0123456789abzAZ")                     # the run breakers
    + [chr(c) for c in range(0x0660, 0x066A)]        # Arabic-Indic digits
)


def fuzz_cases(n, seed=20261004):
    rnd = random.Random(seed)
    out = []
    for _ in range(n):
        k = rnd.randint(0, 12)
        out.append("".join(rnd.choice(ALPHABET) for _ in range(k)))
    return out


def odin_lit(s):
    out = []
    for ch in s:
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append("\\x%02x" % ord(ch))
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def emit(font, cases, fuzz):
    rows = [(c, oracle_forms(font, c)) for c in cases]
    frows = [(c, oracle_forms(font, c)) for c in fuzz]
    L = []
    w = L.append
    w("package palmy_tests")
    w("")
    w("// BEGIN GENERATED -- do not edit by hand.")
    w("//")
    w("// tools/arabic/hb-oracle.py, from harfbuzz %s shaping" % hb.hb_version_string().decode())
    w("// %s." % os.path.basename(FONT))
    w("//")
    w("// Each row is an input string and, per input character, the positional form")
    w("// harfbuzz's GSUB chose for it:")
    w("//")
    w("//\tX isolated   I initial   M medial   F final")
    w("//\tL lam-alef ligature, final      J lam-alef ligature, isolated")
    w("//\t~ a letter a ligature swallowed  . not an Arabic letter")
    w("//")
    w("// Glyph ids and glyph counts are deliberately not here: see the header of")
    w("// the generator for what is and is not comparable between a GSUB shaper and")
    w("// presentation forms.")
    w("//")
    w("// Regenerate with")
    w("//")
    w("//\tpython3 tools/arabic/hb-oracle.py --emit > tests/arabic_oracle.odin")
    w("")
    w("Oracle_Case :: struct {")
    w("\ttext:  string,")
    w("\tforms: string,")
    w("}")
    w("")
    w("// The hand-built corpus: tools/arabic/corpus.txt, %d cases." % len(rows))
    w("ARABIC_ORACLE := [?]Oracle_Case {")
    for text, forms in rows:
        w("\t{%s, %s}," % (odin_lit(text), odin_lit(forms)))
    w("}")
    w("")
    w("// %d random strings from a fixed seed, so the fuzz comparison against" % len(frows))
    w("// harfbuzz is reproducible without harfbuzz being present.")
    w("ARABIC_ORACLE_FUZZ := [?]Oracle_Case {")
    for text, forms in frows:
        w("\t{%s, %s}," % (odin_lit(text), odin_lit(forms)))
    w("}")
    w("")
    w("// END GENERATED")
    print("\n".join(L))


def compare(font, path, cases):
    """Compare palmy's dumped shaping against the oracle, case by case."""
    lines = open(path, encoding="utf-8").read().split("\n")
    assert len(lines) >= len(cases), "%d dumped lines for %d cases" % (len(lines), len(cases))
    bad = 0
    adv_ok = adv_bad = adv_skip = 0
    checked = 0
    for text, line in zip(cases, lines):
        mine, cps = decode_dump(text, line)
        want = oracle_forms(font, text)
        checked += 1
        if mine != want:
            bad += 1
            if bad <= 20:
                print("MISMATCH %r\n  palmy %s\n  hbuzz %s" % (text, mine, want), file=sys.stderr)
        hb_total, my_total = advance_sum(font, text, cps)
        if my_total is None:
            adv_skip += 1
        elif abs(hb_total - my_total) == 0:
            adv_ok += 1
        else:
            adv_bad += 1
            if adv_bad <= 10:
                print("ADVANCE %r hb=%d palmy=%d" % (text, hb_total, my_total), file=sys.stderr)
    print("forms: %d compared, %d mismatched" % (checked, bad))
    print("advance: %d identical, %d different, %d not measurable" % (adv_ok, adv_bad, adv_skip))
    return bad


def decode_dump(text, line):
    """Turn one line of the palmy dumper into the same per-character code."""
    codes = {off: "." for off, _ in _offsets(text)}
    cps = []
    for field in line.split():
        hexcp, form, src, size, lig = field.split(":")
        cp, src, size = int(hexcp, 16), int(src), int(size)
        cps.append(cp)
        ch = text[len(text.encode("utf-8")[:src].decode("utf-8"))]
        if lig == "L":
            codes[src] = "L" if form == "Final" else "J"
            # the alef is the last character of the span
            tail = src + size
            prev = [o for o, _ in _offsets(text) if o < tail][-1]
            codes[prev] = "~"
        elif ord(ch) in SHAPABLE:
            codes[src] = {"Isolated": "X", "Initial": "I", "Medial": "M", "Final": "F"}[form]
    return "".join(codes[o] for o, _ in _offsets(text)), cps


def main():
    font = Font(FONT)
    cases = read_corpus()
    fuzz = fuzz_cases(int(os.environ.get("FUZZ", "400")))
    if "--emit" in sys.argv:
        emit(font, cases, fuzz)
        return
    if "--compare" in sys.argv:
        path = sys.argv[sys.argv.index("--compare") + 1]
        which = cases + fuzz if "--fuzz" in sys.argv else cases
        sys.exit(1 if compare(font, path, which) else 0)
    if "--cases" in sys.argv:
        which = cases + fuzz if "--fuzz" in sys.argv else cases
        sys.stdout.write("\n".join(c.replace("\n", "") for c in which) + "\n")
        return
    print(__doc__)


main()
