#!/usr/bin/env python3
"""Generate apps/emoji/chars.odin.

Nothing here is written from memory. Two real sources on this machine are
intersected:

  * the Unicode Character Database, via Python's `unicodedata` module, which is
    generated from UnicodeData.txt (this interpreter reports Unicode 16.0.0);
    it supplies the official character name and the general category.

  * the cmap of the font the picker renders with, via `fc-query --format
    %{charset}`. A codepoint the font has no glyph for is not offered, because
    a grid of .notdef boxes is not a character picker.

Run:  python3 apps/emoji/gen-chars.py  > /dev/null
"""

import subprocess
import sys
import unicodedata

FONT = "/usr/share/fonts/TTF/DejaVuSans.ttf"
OUT = "/home/alex/Work/palmy/apps/emoji/chars.odin"

# (category label, [(lo, hi), ...], extra single codepoints)
BLOCKS = [
    ("Arrows", [(0x2190, 0x21FF), (0x27F0, 0x27FF), (0x2900, 0x297F), (0x2B00, 0x2B11)], []),
    ("Maths", [(0x2200, 0x22FF), (0x2A00, 0x2AFF), (0x2980, 0x29FF), (0x27C0, 0x27EF)],
     [0x00B1, 0x00D7, 0x00F7, 0x00AC, 0x00B0, 0x00B5]),
    ("Punctuation", [(0x2000, 0x206F), (0x2E00, 0x2E44)],
     [0x00A1, 0x00BF, 0x00AB, 0x00BB, 0x00A7, 0x00B6, 0x00A9, 0x00AE, 0x2122]),
    ("Currency", [(0x20A0, 0x20BF)], [0x00A2, 0x00A3, 0x00A4, 0x00A5, 0x0024, 0x00A6]),
    ("Symbols", [(0x2600, 0x26FF), (0x2700, 0x27BF)], []),
    ("Technical", [(0x2300, 0x23FF), (0x2400, 0x2426)], []),
    ("Shapes", [(0x25A0, 0x25FF), (0x2580, 0x259F)], []),
    ("Box drawing", [(0x2500, 0x257F)], []),
    ("Greek", [(0x0370, 0x03FF), (0x1D6A8, 0x1D7CB)], []),
    ("Cyrillic", [(0x0400, 0x04FF)], []),
    ("Latin", [(0x00C0, 0x024F)], []),
    ("Letterlike", [(0x2100, 0x214F), (0x2150, 0x218F)], []),
    ("Super & sub", [(0x2070, 0x209F)], [0x00B2, 0x00B3, 0x00B9, 0x00BC, 0x00BD, 0x00BE]),
    ("Emoticons", [(0x1F600, 0x1F64F)], []),
    ("Games", [(0x2654, 0x267F), (0x2680, 0x2689), (0x1F030, 0x1F093), (0x1F0A0, 0x1F0DF)], []),
    ("Music", [(0x2669, 0x266F), (0x1D100, 0x1D1FF)], []),
    ("Braille", [(0x2800, 0x28FF)], []),
]

# Extra search terms, because the Unicode name is formal and people are not.
# Keyed by codepoint; these are additions, never replacements.
ALIASES = {
    0x2192: "right next forward",
    0x2190: "left back previous",
    0x2191: "up",
    0x2193: "down",
    0x2713: "check tick done yes ok",
    0x2714: "check tick done yes ok bold",
    0x2717: "cross no fail",
    0x2718: "cross no fail bold",
    0x2716: "cross multiply no",
    0x2605: "star favourite favorite filled",
    0x2606: "star favourite favorite outline",
    0x2665: "heart love",
    0x2764: "heart love",
    0x2022: "bullet list dot point",
    0x2026: "ellipsis dots etc",
    0x2014: "em dash punctuation",
    0x2013: "en dash range",
    0x00A9: "copyright",
    0x00AE: "registered trademark",
    0x2122: "trademark tm",
    0x20AC: "euro money currency",
    0x00A3: "pound sterling money currency",
    0x00A5: "yen yuan money currency",
    0x0024: "dollar money currency",
    0x2318: "command cmd mac key apple",
    0x2325: "option alt mac key",
    0x21E7: "shift key",
    0x232B: "backspace delete key",
    0x23CE: "return enter key",
    0x238B: "escape esc key",
    0x21E5: "tab key",
    0x2423: "space bar key",
    0x00B0: "degree temperature",
    0x00B5: "micro mu",
    0x221E: "infinity",
    0x2248: "approximately approx almost equal",
    0x2260: "not equal neq",
    0x2264: "less than or equal leq",
    0x2265: "greater than or equal geq",
    0x00D7: "times multiply cross",
    0x00F7: "divide division",
    0x00B1: "plus minus tolerance",
    0x221A: "square root sqrt",
    0x2211: "sum sigma total",
    0x220F: "product pi",
    0x222B: "integral",
    0x2202: "partial derivative",
    0x2207: "nabla gradient del",
    0x2208: "element of in member",
    0x2205: "empty set null nothing",
    0x2227: "and conjunction",
    0x2228: "or disjunction",
    0x00AC: "not negation",
    0x2200: "for all universal",
    0x2203: "exists existential",
    0x263A: "smile happy face",
    0x2639: "frown sad face",
    0x2615: "coffee tea hot drink",
    0x26A0: "warning caution alert",
    0x2691: "flag",
    0x2630: "menu hamburger trigram lines",
    0x25B6: "play triangle right",
    0x25C0: "rewind triangle left",
    0x23F8: "pause",
    0x23F9: "stop",
    0x2714: "check done",
    0x2026: "ellipsis",
    0x00AB: "quote guillemet left",
    0x00BB: "quote guillemet right",
    0x201C: "quote double open curly smart",
    0x201D: "quote double close curly smart",
    0x2018: "quote single open curly",
    0x2019: "quote single close curly apostrophe",
    0x2190 + 0x40: "",
}

SKIP_CATEGORIES = {"Cc", "Cf", "Cs", "Co", "Cn", "Mn", "Me", "Mc", "Zl", "Zp", "Zs"}


def font_charset(path):
    out = subprocess.run(
        ["fc-query", "--format", "%{charset}", path], capture_output=True, text=True
    )
    if out.returncode != 0:
        sys.exit(f"fc-query failed on {path}")
    cps = set()
    for tok in out.stdout.split():
        if "-" in tok:
            a, b = tok.split("-")
            cps.update(range(int(a, 16), int(b, 16) + 1))
        else:
            cps.add(int(tok, 16))
    return cps


def main():
    have = font_charset(FONT)
    rows = []
    seen = set()
    counts = []

    for label, ranges, extras in BLOCKS:
        start = len(rows)
        cps = []
        for lo, hi in ranges:
            cps.extend(range(lo, hi + 1))
        cps.extend(extras)
        for cp in cps:
            if cp in seen or cp not in have:
                continue
            ch = chr(cp)
            try:
                name = unicodedata.name(ch)
            except ValueError:
                continue
            if unicodedata.category(ch) in SKIP_CATEGORIES:
                continue
            seen.add(cp)
            alias = ALIASES.get(cp, "")
            rows.append((cp, ch, name, alias, label))
        counts.append((label, len(rows) - start))

    rows_by_cat = {}
    for r in rows:
        rows_by_cat.setdefault(r[4], []).append(r)

    cats = [c for c, n in counts if n > 0]

    def esc(s):
        return s.replace("\\", "\\\\").replace('"', '\\"')

    lines = []
    lines.append("package main")
    lines.append("")
    lines.append("// Generated by apps/emoji/gen-chars.py — do not edit by hand.")
    lines.append("//")
    lines.append("// Names and general categories come from Python's `unicodedata`, which is")
    lines.append(
        f"//   the Unicode Character Database at version {unicodedata.unidata_version}."
    )
    lines.append("// The set of codepoints is the intersection of those blocks with the cmap of")
    lines.append(f"//   {FONT},")
    lines.append("//   read with `fc-query --format %{charset}`. Nothing is offered that the")
    lines.append("//   font cannot actually draw.")
    lines.append("")
    lines.append("Char :: struct {")
    lines.append("\tcp:    rune,")
    lines.append("\ts:     string, // the UTF-8 encoding, ready to copy")
    lines.append("\tname:  string, // the official Unicode name")
    lines.append("\talias: string, // extra search terms")
    lines.append("\tcat:   int,    // index into CATEGORIES")
    lines.append("}")
    lines.append("")
    lines.append(f"UNICODE_VERSION :: \"{unicodedata.unidata_version}\"")
    lines.append(f"GLYPH_FONT :: \"{FONT}\"")
    lines.append("")
    lines.append("CATEGORIES := [?]string{")
    for c in cats:
        lines.append(f'\t"{c}",')
    lines.append("}")
    lines.append("")
    lines.append("CHARS := [?]Char{")
    for cat_i, c in enumerate(cats):
        lines.append(f"\t// --- {c} ({len(rows_by_cat[c])}) ---")
        for cp, ch, name, alias, _ in rows_by_cat[c]:
            lines.append(
                f'\t{{0x{cp:04X}, "{esc(ch)}", "{esc(name)}", "{esc(alias)}", {cat_i}}},'
            )
    lines.append("}")
    lines.append("")

    with open(OUT, "w") as f:
        f.write("\n".join(lines))

    print(f"wrote {OUT}: {len(rows)} characters in {len(cats)} categories", file=sys.stderr)
    for c in cats:
        print(f"  {c:14} {len(rows_by_cat[c])}", file=sys.stderr)


main()
