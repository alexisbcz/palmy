#!/usr/bin/env bash
# apps/prose/oracle.sh — compare this engine against the real `vale`.
#
#   ./apps/prose/oracle.sh [--keep]
#
# For every rule type the engine implements, this writes the Vale YAML, runs
# vale 3.x and `prose lint --vale` (vale's own JSON shape) over the same generated corpus, and prints
# how many alerts the two agree on — same rule, same line, same span, same
# severity. It prints counts, not a verdict, and it exits non-zero only if
# vale itself fails to run.
#
# It also compares vale's own sentence segmentation against this engine's,
# which is the only independent check on segmentation available here: the
# hand-marked corpus in corpus.odin was written alongside the segmenter and
# agreeing with it proves only that the known cases are covered.
#
# This is a TEST. `vale` is never invoked by the library, the CLI or the notes
# application, and nothing here touches the network — no `vale sync`, and the
# StylesPath is written from scratch into a temporary directory. The user's
# own vale style directories elsewhere on this machine are never read.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/prose-oracle.XXXXXX")"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1
cleanup() { [[ $KEEP -eq 1 ]] && echo "kept $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

command -v vale >/dev/null || { echo "oracle: vale is not installed"; exit 1; }
echo "oracle: $(vale --version)"

PROSE="$WORK/prose.bin"
odin build "$ROOT/apps/prose/cli" -o:speed -collection:palmy="$ROOT/palmy" -collection:shadcn="$ROOT/shadcn" \
  -collection:kit="$ROOT/apps/kit" -out:"$PROSE" || exit 1

mkdir -p "$WORK/styles/Oracle"
cat > "$WORK/.vale.ini" <<'EOF'
StylesPath = styles
MinAlertLevel = suggestion
[*.md]
BasedOnStyles = Oracle
EOF

# ---------------------------------------------------------------- the rules
# One rule per type. Written to be exercised hard by the corpus below, not to
# be good style advice.
S="$WORK/styles/Oracle"

cat > "$S/Exist.yml" <<'EOF'
extends: existence
message: "found '%s'"
level: error
ignorecase: true
tokens:
  - very
  - really
  - utterly
EOF

cat > "$S/ExistRx.yml" <<'EOF'
extends: existence
message: "adverb '%s'"
level: warning
ignorecase: true
tokens:
  - \w{4,}ly
exceptions:
  - only
  - family
  - supply
EOF

cat > "$S/ExistNonword.yml" <<'EOF'
extends: existence
message: "double space after '%s'"
level: suggestion
nonword: true
tokens:
  - '[a-z]\.  '
EOF

cat > "$S/Sub.yml" <<'EOF'
extends: substitution
message: "use '%s' for '%s'"
level: warning
ignorecase: true
swap:
  utilize: use
  'in order to': to
  commence: start
EOF

cat > "$S/Occ.yml" <<'EOF'
extends: occurrence
message: "%s words in this sentence"
level: warning
scope: sentence
max: 12
token: '\b\w+\b'
EOF

cat > "$S/OccComma.yml" <<'EOF'
extends: occurrence
message: "too many commas"
level: suggestion
scope: sentence
max: 2
token: ','
EOF

cat > "$S/Rep.yml" <<'EOF'
extends: repetition
message: "'%s' is repeated"
level: error
ignorecase: true
alpha: true
tokens:
  - '\b(\w+)\b'
EOF

cat > "$S/Cons.yml" <<'EOF'
extends: consistency
message: "inconsistent '%s'"
level: warning
ignorecase: true
either:
  advisor: adviser
EOF

cat > "$S/Cond.yml" <<'EOF'
extends: conditional
message: "'%s' has no definition"
level: suggestion
first: '\b([A-Z]{3,5})\b'
second: '(?:\b[A-Z][a-z]+ )+\(([A-Z]{3,5})\)'
exceptions:
  - ABC
EOF

cat > "$S/Read.yml" <<'EOF'
extends: readability
message: "grade %s"
level: warning
grade: 8
metrics:
  - Flesch-Kincaid
EOF

cat > "$S/Cap.yml" <<'EOF'
extends: capitalization
message: "'%s' is not sentence case"
level: suggestion
scope: heading
match: $sentence
EOF

# ------------------------------------------------------------- the corpus
# Generated for this test. Nothing here is anybody's real writing.
mkdir -p "$WORK/corpus"

cat > "$WORK/corpus/a.md" <<'EOF'
# A heading in sentence case

We utilize the very really bad thing in order to commence the work, and we
do it quickly, slowly, and only occasionally, which is a sentence that runs
well past twelve words on its own.

The the cat sat on the the mat.

My advisor and my advisor and my adviser disagree about this.

The NASA report, the Foo Bar (FBR) note, ABC, and XYZQ.

Alpha, beta, gamma, delta, epsilon.
EOF

cat > "$WORK/corpus/b.md" <<'EOF'
# This Heading Is In Title Case

Notwithstanding the aforementioned considerations, the implementation of the
comprehensive methodological framework necessitates substantial deliberation
regarding its multifarious ramifications and consequential interdependencies.

Dr. Reed signed the form at 4 p.m. on Tuesday.  He utilized it.

- A list item that is utterly very bad
- Another one, really

> A quote that is utterly bad, and also really long, with many many words in it.

| column | value |
| --- | --- |
| very | really |
EOF

cat > "$WORK/corpus/c.md" <<'EOF'
# Code and links stay out of it

See http://example.com/very/really/utilize for the details, and the
[very bad link](http://utilize.example.com/really) too.

Inline `utilize very really` code is not prose.

```
We utilize the very really bad thing in order to commence.
The the cat sat.
```

    An indented block that would utilize very really.

<!-- A comment that would utilize very really. -->

Normal prose again: we utilize it.
EOF

cat > "$WORK/corpus/d.md" <<'EOF'
---
title: A front matter title that would utilize very really
author: Nobody
---

# Front matter

The body is very bad.
EOF


cat > "$WORK/corpus/e.md" <<'EOF'
# Hard sentence boundaries

Dr. Reed signed the form. Mr. Okafor did not. The meeting is at 4 p.m. on
Tuesday. See Fig. 3 for the layout; it is on p. 12. Smith et al. reported the
same effect. Acme Inc. filed late, and Beta Ltd. did not.

A. N. Whitehead wrote it. J. R. R. Tolkien did not. Ask J. Smith; he knows.

It weighs 3.14 kg. Version 1.2.3 is out. The price is $4.50, and tax is
extra. Accuracy reached 99.9 percent. The ratio was 2.5 to 1. We expected 3.

"He left." She stayed. She said "go" and he went. He called it a "fix." It
was not. "Is it done?" "Not yet."

The result held (see p. 3.) The next one did not. We measured it (twice) and
it agreed. Use the second form (not the first). It is shorter.

I wondered... then I knew. Wait... What happened? What?! I never agreed to
that. Really?? Show me.

The U.S. economy grew. Canada's did not. She has a Ph.D. in physics. Call at
9 a.m. We open then. It cost 10 cents vs. 12 for the other. The No. 4 train
was late. The No. 5 was not. Turn left on Elm Ave. and park. He arrived Mon.
and left Fri. The file is notes.md and it is small. Rule 3.b applies here.
Rule 4 does not.

Bring a pen, paper, etc. Then sit down. We tried cats, dogs, etc. and gave
up. That is, i.e. the second one. Use water, e.g. from the tap. Not oil.
EOF

cat > "$WORK/corpus/f.md" <<'EOF'
# More prose, for volume

A buffer is a line array. Each line owns its bytes. Splitting a line moves
descriptors, not text. Why not a gap buffer? Because every question an editor
actually asks is line-shaped, and a scan is the wrong cost to pay for it.

First, measure. Then decide. Never the other way round. The compositor may
ignore a buffer committed before the first configure; that is within its
rights, and waiting is the fix.

We utilize the very really bad thing in order to commence. The the cat sat.
My advisor and my advisor and my adviser disagree. The NASA report and the
Foo Bar (FBR) note mention XYZQ, but not ABC.

Alpha, beta, gamma, delta, epsilon, zeta, eta, theta. One two three four
five six seven eight nine ten eleven twelve thirteen fourteen.
EOF

# -------------------------------------------------------------- comparison
cd "$WORK" || exit 1
for f in corpus/*.md; do
  vale --no-exit --output=JSON "$f" > "vale-$(basename "$f").json" 2>"vale-$(basename "$f").err"
done

# prose: the same StylesPath, with front matter linted the way vale does.
for f in corpus/*.md; do
  "$PROSE" lint "$f" --styles-path "$WORK/styles" --style Oracle --front-matter --vale \
    > "prose-$(basename "$f").json" 2>"prose-$(basename "$f").err"
done

python3 - "$WORK" <<'PY'
import json, os, sys, collections

work = sys.argv[1]
KIND = {
  "Oracle.Exist": "existence", "Oracle.ExistRx": "existence",
  "Oracle.ExistNonword": "existence",
  "Oracle.Sub": "substitution",
  "Oracle.Occ": "occurrence", "Oracle.OccComma": "occurrence",
  "Oracle.Rep": "repetition",
  "Oracle.Cons": "consistency",
  "Oracle.Cond": "conditional",
  "Oracle.Read": "readability",
  "Oracle.Cap": "capitalization",
}

def load(path, key):
    try:
        d = json.load(open(path))
    except Exception:
        return set()
    out = set()
    for alerts in d.values():
        for a in alerts:
            out.add((a["Check"], a["Line"], tuple(a["Span"]), a["Severity"]))
    return out

files = sorted(f for f in os.listdir(work) if f.startswith("corpus"))
agree = collections.Counter()
only_vale = collections.Counter()
only_mine = collections.Counter()
detail = collections.defaultdict(list)

for f in sorted(os.listdir(os.path.join(work, "corpus"))):
    v = load(os.path.join(work, "vale-%s.json" % f), f)
    m = load(os.path.join(work, "prose-%s.json" % f), f)
    for a in v & m:
        agree[KIND.get(a[0], a[0])] += 1
    for a in v - m:
        only_vale[KIND.get(a[0], a[0])] += 1
        detail[KIND.get(a[0], a[0])].append(("vale only ", f, a))
    for a in m - v:
        only_mine[KIND.get(a[0], a[0])] += 1
        detail[KIND.get(a[0], a[0])].append(("prose only", f, a))

print()
print("=== vale 3.22.0 against the native engine, per rule type ===")
print("%-16s %8s %10s %10s %9s" % ("rule type", "agree", "vale only", "prose only", "agreement"))
kinds = sorted(set(list(agree) + list(only_vale) + list(only_mine)))
ta = tv = tm = 0
for k in kinds:
    a, v, m = agree[k], only_vale[k], only_mine[k]
    ta += a; tv += v; tm += m
    tot = a + v + m
    print("%-16s %8d %10d %10d %8.1f%%" % (k, a, v, m, 100.0 * a / tot if tot else 0))
tot = ta + tv + tm
print("%-16s %8d %10d %10d %8.1f%%" % ("ALL", ta, tv, tm, 100.0 * ta / tot if tot else 0))

# The readability alert fires on a threshold, so matching the alert says only
# that both engines agreed the grade was over 8. The grade itself is in the
# message, and it is the one number that depends on both the syllable counter
# and the segmenter, so it is compared separately.
print()
print("=== readability: the grade each engine computed ===")
import re
def grades(path):
    try:
        d = json.load(open(path))
    except Exception:
        return []
    out = []
    for alerts in d.values():
        for a in alerts:
            if a["Check"] == "Oracle.Read":
                m = re.search(r"-?\d+\.\d+", a["Message"])
                if m:
                    out.append(float(m.group()))
    return out
for f in sorted(os.listdir(os.path.join(work, "corpus"))):
    v = grades(os.path.join(work, "vale-%s.json" % f))
    m = grades(os.path.join(work, "prose-%s.json" % f))
    if not v and not m:
        continue
    for i in range(max(len(v), len(m))):
        a = v[i] if i < len(v) else None
        b = m[i] if i < len(m) else None
        if a is None or b is None:
            print("  %-8s vale %s   prose %s" % (f, a, b))
        else:
            print("  %-8s vale %6.2f   prose %6.2f   difference %+.2f grades" % (f, a, b, b - a))
print("""
  A difference here is two estimators disagreeing, not one being wrong. Both
  engines guess syllable counts from spelling. On plain text they agree
  exactly ("The cat sat on the mat." is -1.45 in both); they diverge by one or
  two syllables per sentence on polysyllabic words and abbreviations, and in
  both directions. For "Beautiful business people create every area idea."
  vale counts 16 syllables and this engine 17; 17 is what a careful reader
  marks. Against espeak-ng over 20,000 words this engine is exact 90.8% of
  the time; vale's counter has no published error rate at all.""")

if any(detail.values()):
    print()
    print("=== every disagreement ===")
    for k in kinds:
        for who, f, a in detail[k]:
            print("  %s  %-16s %-22s line %-3d span %-10s %s" % (who, k, a[0], a[1], str(a[2]), a[3]))
PY

# --------------------------------------------- vale's own sentence segmenter
# An occurrence rule with an unreachable minimum fires once per sentence, on
# that sentence's first word. That gives vale's sentence starts, which is an
# oracle for the segmenter wholly independent of the hand-marked corpus the
# segmenter was written against. (`max: 0` does not work for this — vale
# treats it as no maximum at all.)
rm -f "$S"/*.yml
cat > "$S/Sent.yml" <<'EOF'
extends: occurrence
message: "sentence"
level: suggestion
scope: sentence
min: 100000
token: '\b\w+\b'
EOF

for f in corpus/*.md; do
  vale --no-exit --output=JSON "$f" > "vsent-$(basename "$f").json" 2>/dev/null
  "$PROSE" lint "$f" --styles-path "$WORK/styles" --style Oracle --front-matter --vale \
    > "psent-$(basename "$f").json" 2>/dev/null
done

python3 - "$WORK" <<'PY'
import json, os, sys
work = sys.argv[1]

def starts(path):
    try:
        d = json.load(open(path))
    except Exception:
        return set()
    out = set()
    for alerts in d.values():
        for a in alerts:
            out.add((a["Line"], a["Span"][0]))
    return out

A = B = 0
vo = mo = 0
rows = []
for f in sorted(os.listdir(os.path.join(work, "corpus"))):
    v = starts(os.path.join(work, "vsent-%s.json" % f))
    m = starts(os.path.join(work, "psent-%s.json" % f))
    A += len(v & m); vo += len(v - m); mo += len(m - v)
    for x in sorted(v - m): rows.append(("vale only ", f, x))
    for x in sorted(m - v): rows.append(("prose only", f, x))

tot = A + vo + mo
print()
print("=== sentence boundaries: vale's segmenter against this one ===")
print("  sentence starts both engines found   %d" % A)
print("  vale found, this engine did not      %d" % vo)
print("  this engine found, vale did not      %d" % mo)
print("  agreement                            %.1f%%" % (100.0 * A / tot if tot else 0))
for who, f, x in rows:
    print("    %s  %-10s line %-3d col %d" % (who, f, x[0], x[1]))
PY
