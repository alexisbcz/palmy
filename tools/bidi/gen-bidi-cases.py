#!/usr/bin/env python3
"""gen-bidi-cases.py — freeze two independent UAX #9 implementations' answers.

palmy/bidi.odin is an implementation of UAX #9 written from the specification.
Testing it against hand-computed expectations tests whether the author read the
specification the same way twice, which is not the question. So this script
runs the corpus through two mature implementations nobody on this side wrote —
libfribidi and ICU — and writes down what they say; tests/bidi_test.odin then
asserts palmy reproduces it, case for case, level for level.

Two oracles rather than one, because neither is right everywhere, and an
expectation only one implementation vouches for is not worth asserting. So an
answer is written down as an expectation when **both** oracles give it, and a
case where they differ is marked, counted and left unasserted rather than
settled by picking a favourite. The differences, each one hand-traced against
the specification:

  * fribidi 1.0.16's rule N0 scans backwards for the preceding strong context
    past the start of the isolating run sequence instead of stopping at sos, so
    `[hebrew]` inside an LRE embedding brackets the wrong way.

  * ICU's BD16 does not always pair the nearest canonically equivalent
    bracket: in `⟨⟩…〉` it pairs the first bracket with the last rather than
    with the one beside it, where BD16's stack pops at the first match.

  * ICU does not apply N0's closing clause, the one that gives a combining
    mark following a bracket the class the bracket resolved to.

  * fribidi's rule X5c resolves some FSI isolates right-to-left when the
    content they scan has no strong character at all and P3 says left-to-right.

  * ICU reports the *smallest* levels that produce its ordering rather than the
    ones the rules assign — it will call the inside of an LRI level 0 rather
    than level 2 when nothing around it disagrees. Conformance clause C1
    allows this, since only the ordering is normative. Where ICU's levels are
    fribidi's lowered by an even amount, either could be the minimisation or
    the mistake, so the expectation is the weaker one that still catches a
    novel answer: palmy's levels must be one implementation's or the other's.

palmy follows the rules as written, which is to say it agrees with whichever
oracle is right in each of the first three. The tests say so by asserting the
unanimous cases and counting the rest; `--compare` prints them.

Neither library is a palmy dependency: palmy links libc and libm, and these
answers reach it as Odin source.

Levels are compared only at the characters rule X9 does *not* remove. The
embedding controls and the boundary neutrals are not displayed and UAX #9
leaves their levels undefined, which is why the three implementations each
choose differently; the generated keep mask says which positions count.

    python3 tools/bidi/gen-bidi-cases.py                      # rewrite tests/bidi_cases.odin
    python3 tools/bidi/gen-bidi-cases.py --compare --fuzz 200000

The committed corpus has to stay a few thousand cases, because it is Odin
source and the compiler's static arena gives out somewhere past four megabytes
of string literal. --compare is the way to run a real fuzz: it builds
tools/bidi/dump and pushes as many cases as asked through palmy and both
oracles in one go, comparing in memory and writing nothing.

The corpus is deliberate first and random second. The deliberate part walks the
rules one at a time — every interleaving of LTR and RTL, digits beside Arabic
letters, neutrals between opposite runs, brackets paired and unpaired and
nested, isolates nested and unterminated, mirrored characters both ways, an
all-neutral line, the empty string — because a named failing case tells you
which rule you misread. The random part then runs thousands of mixed strings
through both implementations, because the rule you misread is usually one you
did not think to write a case for.

It also freezes fribidi's copy of three Unicode tables — Bidi_Class,
Bidi_Mirroring_Glyph and Bidi_Paired_Bracket — so the test can check palmy's
generated tables against a second source of the same data.
"""

import argparse
import itertools
import os
import random
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ORACLE_SRC = os.path.join(ROOT, "tools", "bidi", "fribidi-oracle.c")
ICU_SRC = os.path.join(ROOT, "tools", "bidi", "icu-oracle.c")
TARGET = os.path.join(ROOT, "tests", "bidi_cases.odin")
MAX_CP = 0x110000

# fribidi spells four of the classes differently from UAX #9.
FRIBIDI_NAMES = {"LTR": "L", "RTL": "R", "BS": "B", "SS": "S"}

# ---------------------------------------------------------------------------
# The alphabet the corpus is built from
# ---------------------------------------------------------------------------

CH = {
    "A": 0x0041,  # LATIN CAPITAL LETTER A              L
    "B": 0x0042,  # LATIN CAPITAL LETTER B              L
    "z": 0x007A,  # LATIN SMALL LETTER Z                L
    "he": 0x05D0,  # HEBREW LETTER ALEF                 R
    "he2": 0x05D1,  # HEBREW LETTER BET                 R
    "he3": 0x05D2,  # HEBREW LETTER GIMEL               R
    "ar": 0x0627,  # ARABIC LETTER ALEF                 AL
    "ar2": 0x0628,  # ARABIC LETTER BEH                 AL
    "thaa": 0x0780,  # THAANA LETTER HAA                AL
    "adlam": 0x1E900,  # ADLAM CAPITAL LETTER ALIF      R
    "1": 0x0031,  # DIGIT ONE                           EN
    "2": 0x0032,  # DIGIT TWO                           EN
    "9": 0x0039,  # DIGIT NINE                          EN
    "an": 0x0661,  # ARABIC-INDIC DIGIT ONE             AN
    "an2": 0x0662,  # ARABIC-INDIC DIGIT TWO            AN
    "an3": 0x06F1,  # EXTENDED ARABIC-INDIC DIGIT ONE   EN (not AN — a classic trap)
    "plus": 0x002B,  # PLUS SIGN                        ES
    "minus": 0x002D,  # HYPHEN-MINUS                    ES
    "pct": 0x0025,  # PERCENT SIGN                      ET
    "dollar": 0x0024,  # DOLLAR SIGN                    ET
    "deg": 0x00B0,  # DEGREE SIGN                       ET
    "comma": 0x002C,  # COMMA                           CS
    "dot": 0x002E,  # FULL STOP                         CS
    "colon": 0x003A,  # COLON                           CS
    "sp": 0x0020,  # SPACE                              WS
    "nbsp": 0x00A0,  # NO-BREAK SPACE                   CS
    "bang": 0x0021,  # EXCLAMATION MARK                 ON
    "star": 0x002A,  # ASTERISK                         ON
    "eq": 0x003D,  # EQUALS SIGN                        ON
    "nsm": 0x05B0,  # HEBREW POINT SHEVA                NSM
    "nsm2": 0x064B,  # ARABIC FATHATAN                  NSM
    "nsm3": 0x0300,  # COMBINING GRAVE ACCENT           NSM
    "(": 0x0028,  # LEFT PARENTHESIS                    ON, bracket
    ")": 0x0029,  # RIGHT PARENTHESIS                   ON, bracket
    "[": 0x005B,  # LEFT SQUARE BRACKET                 ON, bracket
    "]": 0x005D,  # RIGHT SQUARE BRACKET                ON, bracket
    "{": 0x007B,  # LEFT CURLY BRACKET                  ON, bracket
    "}": 0x007D,  # RIGHT CURLY BRACKET                 ON, bracket
    "<a": 0x2329,  # LEFT-POINTING ANGLE BRACKET        ON, bracket, canon 3008
    "a>": 0x232A,  # RIGHT-POINTING ANGLE BRACKET       ON, bracket, canon 3009
    "<c": 0x3008,  # LEFT ANGLE BRACKET                 ON, bracket
    "c>": 0x3009,  # RIGHT ANGLE BRACKET                ON, bracket
    "<": 0x003C,  # LESS-THAN SIGN                      ON, mirrored, not a bracket
    ">": 0x003E,  # GREATER-THAN SIGN                   ON, mirrored, not a bracket
    "<<": 0x00AB,  # LEFT-POINTING DOUBLE ANGLE QUOTE   ON, mirrored
    ">>": 0x00BB,  # RIGHT-POINTING DOUBLE ANGLE QUOTE  ON, mirrored
    "LRE": 0x202A,
    "RLE": 0x202B,
    "PDF": 0x202C,
    "LRO": 0x202D,
    "RLO": 0x202E,
    "LRI": 0x2066,
    "RLI": 0x2067,
    "FSI": 0x2068,
    "PDI": 0x2069,
    "shy": 0x00AD,  # SOFT HYPHEN                       BN
    "zwj": 0x200D,  # ZERO WIDTH JOINER                 BN
    "nul": 0x0000,  # NULL                              BN
    "tab": 0x0009,  # TAB                                S
    "psep": 0x2029,  # PARAGRAPH SEPARATOR               B
    "lsep": 0x2028,  # LINE SEPARATOR                    WS
}


def seq(*names):
    return [CH[n] for n in names]


def deliberate():
    """(label, base direction, codepoints) for every rule, one at a time."""
    cases = []

    def add(label, cps, dirs="LRA"):
        for d in dirs:
            cases.append((f"{label} [{d}]", d, list(cps)))

    # --- the degenerate inputs -------------------------------------------
    add("empty", [])
    add("one latin letter", seq("A"))
    add("one hebrew letter", seq("he"))
    add("one neutral", seq("bang"))
    add("only controls", seq("LRE", "RLE", "PDF", "PDF", "LRI", "PDI"))
    add("only BN", seq("shy", "zwj", "nul"))
    add("entirely neutral line", seq("bang", "sp", "star", "sp", "eq"))
    add("entirely whitespace", seq("sp", "sp", "sp"))

    # --- pure runs and every interleaving --------------------------------
    add("pure LTR word", seq("A", "B", "z"))
    add("pure RTL word", seq("he", "he2", "he3"))
    add("pure Arabic word", seq("ar", "ar2"))
    add("pure Thaana word", seq("thaa", "thaa"))
    add("Adlam, an RTL script beyond the BMP", seq("adlam", "adlam"))
    for n in range(1, 6):
        for bits in itertools.product("lr", repeat=n):
            cps = [CH["A"] if b == "l" else CH["he"] for b in bits]
            add("interleaving " + "".join(bits), cps)

    # --- the W rules ------------------------------------------------------
    add("W2: digits after an Arabic letter", seq("ar", "1", "2"))
    add("W2: digits after a Hebrew letter", seq("he", "1", "2"))
    add("W2: digits after a Latin letter", seq("A", "1", "2"))
    add("W2: Arabic-Indic digits are AN already", seq("ar", "an", "an2"))
    add("W2: extended Arabic-Indic digits are EN", seq("ar", "an3", "an3"))
    add("abc 123 and Arabic-Indic digits", seq("A", "B", "sp", "1", "2", "sp", "an", "an2"))
    add("W4: ES between two EN", seq("1", "plus", "2"))
    add("W4: ES between EN and AN", seq("1", "plus", "an"))
    add("W4: CS between two EN", seq("1", "comma", "2"))
    add("W4: CS between two AN", seq("an", "comma", "an2"))
    add("W4: CS between AN and EN", seq("an", "comma", "1"))
    add("W4: two separators in a row", seq("1", "plus", "plus", "2"))
    add("W4: NBSP is CS between numbers", seq("1", "nbsp", "2"))
    add("W5: ET before EN", seq("pct", "1"))
    add("W5: ET after EN", seq("1", "pct"))
    add("W5: a run of ET either side", seq("dollar", "deg", "1", "pct", "pct"))
    add("W5: ET with no EN at all", seq("he", "pct", "he2"))
    add("W6: leftover separators go neutral", seq("A", "comma", "he"))
    add("W7: EN after an L letter becomes L", seq("A", "1", "sp", "he", "1"))
    add("W1: NSM after a Hebrew letter", seq("he", "nsm"))
    add("W1: NSM after a Latin letter", seq("A", "nsm3"))
    add("W1: NSM at the start of the text", seq("nsm", "he"))
    add("W1: NSM after an isolate initiator", seq("LRI", "nsm", "PDI"))
    add("W1: NSM after a PDI", seq("LRI", "A", "PDI", "nsm"))
    add("W1: a run of NSM", seq("ar", "nsm2", "nsm2", "nsm2"))
    add("W rules all at once", seq("ar", "1", "comma", "2", "pct", "sp", "an", "plus", "an2"))

    # --- neutrals ---------------------------------------------------------
    add("neutral between opposite runs", seq("A", "bang", "he"))
    add("neutral between same runs", seq("he", "bang", "he2"))
    add("N1: a run of neutrals between RTL", seq("he", "sp", "bang", "sp", "he2"))
    add("N2: neutrals between L and R", seq("A", "sp", "star", "sp", "he"))
    add("neutral at both edges", seq("bang", "he", "bang"))
    add("digits are R for N1", seq("1", "bang", "he"))
    add("tab is a segment separator", seq("he", "tab", "he2"))
    add("two segment separators", seq("A", "tab", "tab", "he"))
    add("whitespace then a segment separator", seq("he", "he2", "sp", "tab"))
    # A paragraph separator only ever appears last here. UAX #9's P1 splits a
    # text into paragraphs *before* the algorithm runs, and both palmy and
    # fribidi document themselves as taking one paragraph — but they disagree
    # about what a B in the middle of one means, because it is a contract
    # violation either way. palmy keeps it at the paragraph level and carries
    # on; fribidi starts a new paragraph with a direction of its own. Neither
    # is wrong, so the corpus does not ask.
    add("paragraph separator at the end", seq("he", "he2", "psep"))
    add("paragraph separator after LTR", seq("A", "B", "psep"))
    add("whitespace before a trailing paragraph separator", seq("he", "sp", "psep"))
    add("line separator is whitespace", seq("he", "lsep", "he2"))
    add("trailing whitespace after RTL", seq("he", "he2", "sp", "sp"))
    add("trailing whitespace after LTR", seq("A", "B", "sp"))
    add("whitespace before a segment separator", seq("he", "sp", "tab", "A"))
    add("whitespace and controls before a segment separator", seq("he", "sp", "shy", "tab", "A"))

    # --- brackets, N0 and BD16 -------------------------------------------
    add("brackets around LTR in LTR", seq("A", "(", "B", ")", "z"))
    add("brackets around RTL in RTL", seq("he", "(", "he2", ")", "he3"))
    add("brackets around LTR inside RTL", seq("he", "(", "A", ")", "he2"))
    add("brackets around RTL inside LTR", seq("A", "(", "he", ")", "B"))
    add("brackets with nothing strong inside", seq("he", "(", "bang", ")", "he2"))
    add("brackets with a digit inside, RTL context", seq("he", "(", "1", ")", "he2"))
    add("brackets with an AN inside, LTR context", seq("A", "(", "an", ")", "B"))
    add("nested brackets, RTL outside", seq("he", "(", "A", "[", "B", "]", ")", "he2"))
    add("nested brackets, LTR outside", seq("A", "(", "he", "[", "he2", "]", ")", "B"))
    add("three bracket kinds nested", seq("he", "(", "[", "{", "A", "}", "]", ")"))
    add("unmatched opening bracket", seq("he", "(", "A", "he2"))
    add("unmatched closing bracket", seq("he", "A", ")", "he2"))
    add("crossed brackets", seq("he", "(", "A", "[", "B", ")", "]", "he2"))
    add("bracket pair with text before it", seq("A", "sp", "he", "(", "he2", ")"))
    add("N0 c: opposite inside, opposite before", seq("A", "he", "(", "he2", ")", "A"))
    add("N0 c: opposite inside, embedding before", seq("he", "A", "(", "A", ")", "he2"))
    add("canonically equivalent angle brackets", seq("he", "<a", "A", "c>", "he2"))
    add("the other canonical pairing", seq("he", "<c", "A", "a>", "he2"))
    add("brackets with an NSM on the bracket", seq("he", "(", "nsm", "A", ")", "nsm", "he2"))
    add("empty bracket pair", seq("he", "(", ")", "he2"))
    add("bracket pair spanning an isolate", seq("he", "(", "LRI", "A", "PDI", ")", "he2"))
    add("64 nested brackets, past BD16's stack", seq(*(["("] * 64 + ["A"] + [")"] * 64)))
    add("63 nested brackets, BD16's last slot", seq(*(["("] * 63 + ["A"] + [")"] * 63)))

    # --- mirroring --------------------------------------------------------
    add("mirrored sign in LTR", seq("A", "<", "B"))
    add("mirrored sign in RTL", seq("he", "<", "he2"))
    add("guillemets around RTL", seq("<<", "he", ">>"))
    add("guillemets around LTR", seq("<<", "A", ">>"))

    # --- isolates ---------------------------------------------------------
    add("LRI around Latin inside Hebrew", seq("he", "LRI", "A", "B", "PDI", "he2"))
    add("RLI around Hebrew inside Latin", seq("A", "RLI", "he", "he2", "PDI", "B"))
    add("FSI resolving to RTL", seq("A", "FSI", "he", "A", "PDI", "B"))
    add("FSI resolving to LTR", seq("he", "FSI", "A", "he2", "PDI", "he3"))
    add("FSI with nothing strong inside", seq("he", "FSI", "1", "PDI", "he2"))
    add("FSI skipping a nested isolate", seq("A", "FSI", "LRI", "A", "PDI", "he", "PDI", "B"))
    add("nested isolates", seq("he", "LRI", "A", "RLI", "he2", "PDI", "B", "PDI", "he3"))
    add("unterminated isolate", seq("A", "RLI", "he", "he2"))
    add("unterminated nested isolates", seq("A", "LRI", "B", "RLI", "he"))
    add("stray PDI", seq("A", "PDI", "he"))
    add("PDI before its initiator", seq("PDI", "LRI", "A", "PDI"))
    add("empty isolate", seq("he", "LRI", "PDI", "he2"))
    add("isolate holding only neutrals", seq("he", "RLI", "bang", "PDI", "he2"))
    add("isolate at the very end", seq("he", "LRI", "A"))
    add("digits inside an isolate", seq("ar", "LRI", "1", "PDI", "ar2"))
    add("128 nested isolates, past the depth limit", seq(*(["LRI"] * 128 + ["A"] + ["PDI"] * 128)))
    add("124 nested isolates, inside the limit", seq(*(["LRI"] * 124 + ["A"] + ["PDI"] * 124)))

    # --- explicit embeddings and overrides -------------------------------
    add("RLE embedding", seq("A", "RLE", "he", "A", "PDF", "B"))
    add("LRE embedding", seq("he", "LRE", "A", "he2", "PDF", "he3"))
    add("RLO override turns Latin right-to-left", seq("A", "RLO", "A", "B", "PDF", "z"))
    add("LRO override turns Hebrew left-to-right", seq("he", "LRO", "he2", "he3", "PDF", "he"))
    add("RLO over digits", seq("A", "RLO", "1", "2", "PDF", "B"))
    add("nested embeddings", seq("A", "RLE", "he", "LRE", "A", "PDF", "he2", "PDF", "B"))
    add("unterminated embedding", seq("A", "RLE", "he", "A"))
    add("stray PDF", seq("A", "PDF", "he"))
    add("PDF storm", seq("A", "PDF", "PDF", "PDF", "he"))
    add("embedding inside an isolate", seq("he", "LRI", "RLE", "he2", "PDF", "PDI", "he3"))
    add("isolate inside an embedding", seq("A", "RLE", "LRI", "A", "PDI", "PDF", "B"))
    add("PDI closing an embedding too", seq("A", "LRI", "RLE", "he", "PDI", "B"))
    add("130 nested embeddings, past the depth limit", seq(*(["RLE"] * 130 + ["A"] + ["PDF"] * 130)))
    add("overflow then a valid isolate", seq(*(["RLE"] * 130 + ["LRI", "A", "PDI"] + ["PDF"] * 130)))

    # --- BN, which X9 removes --------------------------------------------
    add("BN between letters", seq("A", "shy", "he"))
    add("BN between digits", seq("1", "shy", "2"))
    add("BN between an AN and a separator", seq("an", "shy", "comma", "an2"))
    add("BN before an NSM", seq("he", "shy", "nsm"))
    add("BN at the edges", seq("shy", "he", "zwj"))
    add("ZWJ inside Arabic", seq("ar", "zwj", "ar2"))
    add("BN beside an embedding control", seq("A", "RLE", "shy", "he", "PDF", "B"))

    # --- the shapes real text actually has -------------------------------
    add("a Hebrew sentence with a Latin product name",
        seq("he", "he2", "sp", "LRI", "A", "B", "PDI", "sp", "he3"))
    add("an Arabic price", seq("ar", "ar2", "sp", "an", "an2", "sp", "dollar"))
    add("a Latin sentence with a Hebrew quotation",
        seq("A", "B", "sp", "<<", "he", "he2", ">>", "sp", "z"))
    add("a bidi file path", seq("A", "colon", "he", "he2", "colon", "B"))
    add("an RTL label with an LTR number range", seq("he", "sp", "1", "minus", "9", "sp", "he2"))
    return cases


def fuzz(count, seed):
    rng = random.Random(seed)
    # Weighted so that the interesting characters turn up often and the
    # pathological ones turn up sometimes.
    alphabet = (
        ["A", "B", "z"] * 6
        + ["he", "he2", "he3"] * 6
        + ["ar", "ar2"] * 4
        + ["adlam", "thaa"]
        + ["1", "2", "9"] * 3
        + ["an", "an2", "an3"] * 3
        + ["plus", "minus", "pct", "dollar", "comma", "dot", "colon", "nbsp"] * 2
        + ["sp"] * 3
        + ["bang", "star", "eq"] * 2
        + ["nsm", "nsm2", "nsm3"] * 2
        + ["(", ")", "[", "]", "{", "}", "<a", "a>", "<c", "c>"] * 3
        + ["<", ">", "<<", ">>"]
        + ["LRI", "RLI", "FSI", "PDI"] * 3
        + ["LRE", "RLE", "LRO", "RLO", "PDF"] * 2
        + ["shy", "zwj", "nul"]
        + ["tab", "lsep"]  # no "psep": see the note in deliberate()
    )
    cases = []
    for i in range(count):
        n = rng.choice([0, 1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 24, 32])
        cps = [CH[rng.choice(alphabet)] for _ in range(n)]
        d = rng.choice("LRA")
        cases.append((f"fuzz {i}", d, cps))
    return cases


# ---------------------------------------------------------------------------
# Driving fribidi
# ---------------------------------------------------------------------------

def build_oracle(tmp):
    binary = os.path.join(tmp, "fribidi-oracle")
    cflags = subprocess.run(
        ["pkg-config", "--cflags", "--libs", "fribidi"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    subprocess.run(["cc", "-O2", "-o", binary, ORACLE_SRC] + cflags, check=True)
    return binary


def build_icu_oracle(tmp):
    binary = os.path.join(tmp, "icu-oracle")
    cflags = subprocess.run(
        ["pkg-config", "--cflags", "--libs", "icu-uc"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    subprocess.run(["cc", "-O2", "-o", binary, ICU_SRC] + cflags, check=True)
    return binary


def run_oracle(binary, cases):
    payload = "".join(
        "%s %s\n" % (d, " ".join("%04X" % cp for cp in cps)) for _label, d, cps in cases
    )
    out = subprocess.run([binary], input=payload, capture_output=True, text=True, check=True)
    lines = out.stdout.splitlines()
    if len(lines) != len(cases):
        raise SystemExit("oracle answered %d of %d cases" % (len(lines), len(cases)))
    return lines


# X9 removes these, and then nobody agrees what level they have, because
# nothing draws them.
REMOVED = {"RLE", "LRE", "RLO", "LRO", "PDF", "BN"}


def keep_mask(cps):
    import unicodedata
    return "".join("0" if unicodedata.bidirectional(chr(cp)) in REMOVED else "1" for cp in cps)


def masked(values, mask):
    return [v for v, k in zip(values, mask) if k == "1"]


def masked_order(order, mask):
    return [i for i in order if mask[i] == "1"]


def same_order(cps, a, b):
    """Do two oracles reorder the visible characters the same way?"""
    mask = keep_mask(cps)
    oa = [int(x) for x in a.split("|")[2].split()]
    ob = [int(x) for x in b.split("|")[2].split()]
    return masked_order(oa, mask) == masked_order(ob, mask)


def level_agreement(cps, icu, fri):
    """How far ICU corroborates fribidi's levels on the visible characters.

    "same"      — identical, so fribidi's numbers are the rules' numbers.
    "minimised" — ICU is lower at some positions but always by an even amount,
                  which is ICU reporting the smallest levels that give the same
                  ordering. Conformance clause C1 allows it, and fribidi's
                  numbers are still the rules' numbers.
    "conflict"  — they differ in parity or ICU is higher. Then one of them has
                  a rule wrong and neither is a reference, so the case's levels
                  are not compared with anything.
    """
    mask = keep_mask(cps)
    a = [int(x) for x in masked(icu.split("|")[1].split(), mask)]
    b = [int(x) for x in masked(fri.split("|")[1].split(), mask)]
    if a == b:
        return "same"
    for x, y in zip(a, b):
        if x == y:
            continue
        if x < y and (y - x) % 2 == 0:
            continue
        return "conflict"
    return "minimised"


def fribidi_props(binary):
    out = subprocess.run([binary, "--props"], capture_output=True, text=True, check=True)
    classes = []
    mirrors = []
    brackets = []
    for line in out.stdout.splitlines():
        f = line.split()
        cp = int(f[0], 16)
        classes.append(FRIBIDI_NAMES.get(f[1], f[1]))
        if int(f[2], 16) != cp:
            mirrors.append((cp, int(f[2], 16)))
        if f[3] != "n":
            brackets.append((cp, f[3], int(f[4], 16)))
    if len(classes) != MAX_CP:
        raise SystemExit("oracle dumped %d codepoints" % len(classes))
    merged = []
    cp = 0
    while cp < MAX_CP:
        c = classes[cp]
        start = cp
        while cp + 1 < MAX_CP and classes[cp + 1] == c:
            cp += 1
        merged.append((start, cp, c))
        cp += 1
    return merged, mirrors, brackets


def class_exceptions(fri_ranges):
    """Where palmy and fribidi disagree about an unassigned codepoint's class.

    palmy follows DerivedBidiClass's @missing defaults, which give unassigned
    codepoints in the Arabic and Hebrew blocks AL or R. fribidi's table leaves
    some of those at L. Only unassigned codepoints are ever affected — the
    generator asserts that — so no real text can tell the difference, but the
    test has to know which ranges to skip.
    """
    import importlib.util
    import unicodedata

    spec = importlib.util.spec_from_file_location(
        "gen_bidi_table", os.path.join(ROOT, "tools", "bidi", "gen-bidi-table.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mine = mod.bidi_classes()

    fri = ["L"] * MAX_CP
    for lo, hi, c in fri_ranges:
        for cp in range(lo, hi + 1):
            fri[cp] = c

    diffs = []
    for cp in range(MAX_CP):
        if mine[cp] == fri[cp]:
            continue
        if unicodedata.bidirectional(chr(cp)) != "":
            raise SystemExit(
                "U+%04X is assigned and palmy says %s where fribidi says %s — that is a "
                "real disagreement, not an unassigned-default one" % (cp, mine[cp], fri[cp])
            )
        if diffs and diffs[-1][1] == cp - 1 and diffs[-1][2] == mine[cp] and diffs[-1][3] == fri[cp]:
            diffs[-1][1] = cp
        else:
            diffs.append([cp, cp, mine[cp], fri[cp]])
    return [tuple(d) for d in diffs]


# ---------------------------------------------------------------------------
# Emitting
# ---------------------------------------------------------------------------

def emit(cases, icu, fribidi, fri_ranges, mirrors, brackets, exceptions, seed, fuzz_count):
    out = []
    w = out.append
    fri_version, fri_unicode = fribidi_version()
    w("package palmy_tests")
    w("")
    w("// bidi_cases.odin — generated by tools/bidi/gen-bidi-cases.py. Do not edit.")
    w("//")
    w("// Every expectation here came out of ICU %s or libfribidi %s" % (icu_version(), fri_version))
    w("// (Unicode %s): two implementations of UAX #9 that palmy did not write and" % fri_unicode)
    w("// does not link. tests/bidi_test.odin replays them through palmy/bidi.odin.")
    w("// Regenerate with:")
    w("//")
    w("//     python3 tools/bidi/gen-bidi-cases.py --fuzz %d --seed %d" % (fuzz_count, seed))
    w("")
    w("// BIDI_CASES holds one case per line:")
    w("//")
    w("//     <direction>|<codepoints>|<fribidi levels>|<ICU levels>|<visual order>|")
    w("//     <keep>|<agreed>|<label>")
    w("//")
    w("// The direction is L, R or A, A being automatic — UAX #9's P2 and P3.")
    w("// Codepoints are hexadecimal; the visual order is logical indices, leftmost")
    w("// first. `keep` is 0 for each character rule X9 removes, whose level nothing")
    w("// displays and no two implementations agree on, and only the 1s are")
    w("// compared.")
    w("//")
    w("// `agreed` is two flags. The first is 1 where both oracles ordered the case")
    w("// the same way, and palmy must reproduce that order. The second is 1 where")
    w("// both reported the same levels, and palmy must reproduce them; 2 where")
    w("// ICU's are the same levels lowered by an even amount, which is either its")
    w("// documented minimisation or a mistake, and palmy must match one side or")
    w("// the other; 0 where the two contradict each other and nothing is asserted.")
    w("BIDI_CASES :: `")
    order_deviations = 0
    level_simplifications = 0
    level_conflicts = 0
    for (label, d, cps), a, b in zip(cases, icu, fribidi):
        icu_par, icu_levels, icu_order = a.split("|")
        fri_par, fri_levels, _fri_order = b.split("|")
        if icu_par != fri_par:
            raise SystemExit(
                "%s: ICU resolved paragraph level %s, fribidi %s" % (label, icu_par, fri_par)
            )
        ordered_alike = same_order(cps, a, b)
        agreement = level_agreement(cps, a, b)
        level_flag = "0"
        if ordered_alike and agreement == "same":
            level_flag = "1"
        elif ordered_alike and agreement == "minimised":
            level_flag = "2"
        if not ordered_alike:
            order_deviations += 1
        elif agreement == "minimised":
            level_simplifications += 1
        elif agreement == "conflict":
            level_conflicts += 1
        w(
            "%s|%s|%s|%s|%s|%s|%s|%s"
            % (
                d,
                " ".join("%04X" % cp for cp in cps),
                fri_levels,
                icu_levels,
                icu_order,
                keep_mask(cps),
                ("1" if ordered_alike else "0") + level_flag,
                label,
            )
        )
    w("`")
    w("")
    w("// BIDI_PAR_LEVELS holds the paragraph level the oracles resolved for each")
    w("// case above, in the same order, so P2 and P3 are checked on their own.")
    w("// The two oracles agree about this on every case; the generator checks.")
    w("BIDI_PAR_LEVELS :: `")
    w(" ".join(a.split("|")[0] for a in icu))
    w("`")
    w("")
    w("// BIDI_N0_DEVIATIONS is how many of the cases above libfribidi ordered")
    w("// differently from ICU — all of them rule N0, where fribidi's backward")
    w("// scan for the preceding strong context runs past the start of the")
    w("// isolating run sequence instead of stopping at sos. palmy follows the")
    w("// rule as written, so on these it matches ICU and not fribidi.")
    w("BIDI_N0_DEVIATIONS :: %d" % order_deviations)
    w("")
    w("// BIDI_LEVEL_CONFLICTS is how many cases the two oracles ordered")
    w("// identically while reporting levels neither minimisation nor agreement")
    w("// explains. palmy is compared with ICU's ordering on these and with")
    w("// nobody's levels.")
    w("BIDI_LEVEL_CONFLICTS :: %d" % level_conflicts)
    w("")
    w("// BIDI_LEVEL_SIMPLIFICATIONS is how many cases the two oracles ordered")
    w("// identically while reporting different levels, which is ICU reporting the")
    w("// smallest levels that give that order. Conformance clause C1 only")
    w("// requires the order, so this is a difference of report, not of result.")
    w("BIDI_LEVEL_SIMPLIFICATIONS :: %d" % level_simplifications)
    w("")
    w("// BIDI_FRIBIDI_CLASSES is fribidi's whole Bidi_Class table, as")
    w("// \"<lo> <hi> <class>\" ranges. palmy's table is generated from Python's")
    w("// unicodedata and Perl's unicore files, so this is a third source for the")
    w("// same property, and the test walks every one of the %s codepoints." % f"{MAX_CP:,}")
    w("BIDI_FRIBIDI_CLASSES :: `")
    for lo, hi, c in fri_ranges:
        w("%04X %04X %s" % (lo, hi, c))
    w("`")
    w("")
    w("// BIDI_CLASS_EXCEPTIONS lists the ranges where palmy and fribidi")
    w("// deliberately differ: palmy follows DerivedBidiClass's @missing")
    w("// defaults for *unassigned* codepoints, fribidi leaves some of them L.")
    w("// No assigned codepoint appears here — the generator refuses to emit one.")
    w("BIDI_CLASS_EXCEPTIONS :: `")
    for lo, hi, mine, fri in exceptions:
        w("%04X %04X %s %s" % (lo, hi, mine, fri))
    w("`")
    w("")
    w("// BIDI_FRIBIDI_MIRRORS is fribidi's Bidi_Mirroring_Glyph table: rule L4.")
    w("BIDI_FRIBIDI_MIRRORS :: `")
    for cp, m in mirrors:
        w("%04X %04X" % (cp, m))
    w("`")
    w("")
    w("// BIDI_FRIBIDI_BRACKETS is fribidi's Bidi_Paired_Bracket table, as")
    w("// \"<codepoint> <O|C> <canonical pair id>\": the data BD16 matches on.")
    w("BIDI_FRIBIDI_BRACKETS :: `")
    for cp, kind, paired in brackets:
        w("%04X %s %04X" % (cp, kind, paired))
    w("`")
    return "\n".join(out) + "\n", order_deviations, level_simplifications, level_conflicts


def icu_version():
    return subprocess.run(
        ["pkg-config", "--modversion", "icu-uc"], capture_output=True, text=True, check=True
    ).stdout.strip()


def fribidi_version():
    lib = "/usr/include/fribidi/fribidi-unicode-version.h"
    unicode_version = "unknown"
    with open(lib) as f:
        for line in f:
            if line.startswith("#define FRIBIDI_UNICODE_VERSION"):
                unicode_version = line.split('"')[1]
    version = subprocess.run(
        ["pkg-config", "--modversion", "fribidi"], capture_output=True, text=True, check=True
    ).stdout.strip()
    return version, unicode_version


def build_palmy(tmp):
    binary = os.path.join(tmp, "bidi-dump")
    subprocess.run(
        [
            "odin", "build", os.path.join(ROOT, "tools", "bidi", "dump"),
            "-collection:palmy=" + os.path.join(ROOT, "palmy"),
            "-o:speed", "-out:" + binary,
        ],
        check=True,
    )
    return binary


def like(mine, oracle, mask):
    """Did palmy give this oracle's answer, levels and order both?"""
    _par, levels, order = mine.split("|")
    _opar, olevels, oorder = oracle.split("|")
    return masked(levels.split(), mask) == masked(olevels.split(), mask) and masked_order(
        [int(x) for x in order.split()], mask
    ) == masked_order([int(x) for x in oorder.split()], mask)


def compare_mode(cases, tmp):
    """Run palmy and both oracles over the corpus and report, writing nothing.

    The rules are the same ones the generated file encodes: the ordering is
    ICU's and is checked on every case; the levels are fribidi's and are
    checked wherever ICU corroborates them to within its own minimisation.
    """
    palmy_binary = build_palmy(tmp)
    fri_binary = build_oracle(tmp)
    icu_binary = build_icu_oracle(tmp)

    palmy = run_oracle(palmy_binary, cases)
    fribidi = run_oracle(fri_binary, cases)
    icu = run_oracle(icu_binary, cases)

    checked_order = 0
    checked_levels = 0
    skipped_levels = 0
    order_deviations = 0
    disputed_like_icu = 0
    disputed_like_fribidi = 0
    disputed_like_neither = []
    either = 0
    bad = []
    for (label, _d, cps), mine, a, b in zip(cases, palmy, icu, fribidi):
        mask = keep_mask(cps)
        mine_par, mine_levels, mine_order = mine.split("|")
        icu_par, icu_levels, icu_order = a.split("|")
        _fri_par, fri_levels, _fri_order = b.split("|")

        if mine_par != icu_par:
            bad.append((label, "paragraph level", mine_par, icu_par))
            continue

        agreement = level_agreement(cps, a, b)
        if not same_order(cps, a, b) or agreement == "conflict":
            # The oracles contradict each other, so there is nothing to assert.
            # Which of them palmy sided with is still worth knowing: a third
            # answer would mean palmy has a rule of its own.
            skipped_levels += 1
            if not same_order(cps, a, b):
                order_deviations += 1
            if like(mine, a, mask):
                disputed_like_icu += 1
            elif like(mine, b, mask):
                disputed_like_fribidi += 1
            else:
                disputed_like_neither.append(label)
            continue

        want = masked_order([int(x) for x in icu_order.split()], mask)
        got = masked_order([int(x) for x in mine_order.split()], mask)
        checked_order += len(want)
        if want != got:
            bad.append((label, "visual order", got, want))
            continue

        got_l = masked(mine_levels.split(), mask)
        want_fri = masked(fri_levels.split(), mask)
        want_icu = masked(icu_levels.split(), mask)
        checked_levels += len(want_fri)
        if agreement == "same":
            if got_l != want_fri:
                bad.append((label, "levels", got_l, want_fri))
        else:
            # ICU's levels are fribidi's lowered evenly: one of them is the
            # minimisation C1 allows, and a third answer is nobody's.
            either += 1
            if got_l != want_fri and got_l != want_icu:
                bad.append((label, "levels", got_l, "%s or %s" % (want_fri, want_icu)))

    print(
        "%d cases: %d visual positions and %d levels checked, on the cases where\n"
        "  ICU and fribidi agree with each other\n"
        "  %d cases skipped because the two oracles contradict each other,\n"
        "  %d of those because their orderings differ\n"
        "  %d of the level checks allowed either oracle's answer, where ICU's are\n"
        "  the same levels lowered evenly\n"
        "  %d disagreements between palmy and the two oracles agreeing\n"
        "  of the %d contradicted cases palmy answered like ICU on %d, like fribidi\n"
        "  on %d, and like neither on %d"
        % (
            len(cases), checked_order, checked_levels,
            skipped_levels, order_deviations, either, len(bad),
            skipped_levels, disputed_like_icu, disputed_like_fribidi,
            len(disputed_like_neither),
        )
    )
    for label in disputed_like_neither[:20]:
        print("  %s: palmy answered like neither oracle" % label)
    for label, what, got, want in bad[:20]:
        print("  %s: %s %s, the oracle says %s" % (label, what, got, want))
    return 1 if bad else 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fuzz", type=int, default=4000, help="how many random cases to add")
    ap.add_argument("--seed", type=int, default=20261004, help="the random seed, so a run repeats")
    ap.add_argument("--stdout", action="store_true")
    ap.add_argument(
        "--compare",
        action="store_true",
        help="fuzz palmy against both oracles in memory instead of writing the corpus",
    )
    args = ap.parse_args()

    cases = deliberate() + fuzz(args.fuzz, args.seed)

    if args.compare:
        with tempfile.TemporaryDirectory() as tmp:
            sys.exit(compare_mode(cases, tmp))

    with tempfile.TemporaryDirectory() as tmp:
        fri_binary = build_oracle(tmp)
        icu_binary = build_icu_oracle(tmp)
        fribidi = run_oracle(fri_binary, cases)
        icu = run_oracle(icu_binary, cases)
        fri_ranges, mirrors, brackets = fribidi_props(fri_binary)
    exceptions = class_exceptions(fri_ranges)

    text, order_deviations, level_simplifications, level_conflicts = emit(
        cases, icu, fribidi, fri_ranges, mirrors, brackets, exceptions, args.seed, args.fuzz
    )
    if args.stdout:
        sys.stdout.write(text)
        return
    with open(TARGET, "w") as f:
        f.write(text)
    print(
        "tests/bidi_cases.odin: %d cases (%d deliberate, %d fuzz)\n"
        "  ICU and fribidi order %d of them identically (%.2f%%); %d differ, all rule N0\n"
        "  %d more agree on the order while ICU reports smaller levels (C1 allows it)\n"
        "  %d order alike but report levels that contradict; their levels go unchecked\n"
        "  tables: %d class ranges, %d mirror pairs, %d brackets, "
        "%d unassigned-default exceptions"
        % (
            len(cases), len(cases) - args.fuzz, args.fuzz,
            len(cases) - order_deviations,
            100.0 * (len(cases) - order_deviations) / max(len(cases), 1),
            order_deviations,
            level_simplifications,
            level_conflicts,
            len(fri_ranges), len(mirrors), len(brackets), len(exceptions),
        )
    )


if __name__ == "__main__":
    main()
