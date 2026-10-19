#!/usr/bin/env python3
# Make the live system's Japanese font: Noto Sans CJK's Japanese face, cut
# down to the characters the installer can show in Japanese.
#
#	<python with fontTools> distro/live/subset-cjk.py [NotoSansCJK-Regular.ttc]
#	python3 -I distro/live/subset-cjk.py --check FONT   (no fontTools needed)
#
# The live system runs from RAM, and the whole of Noto Sans CJK Regular is
# 19 MB there for the sake of one screen's worth of text. What the installer
# draws in Japanese is known: its catalogues, distro/locale/ja/*.msg
# (installer, greeter, country names, keyboard descriptions), plus kana,
# CJK punctuation and the full-width forms, so a name typed in or shown
# anywhere else still has its kana. The subset is committed, at
# distro/live/root/usr/share/fonts/palm-live/NotoSansCJKjp-Regular.otf, which
# palmframe-live ships; palmy finds it by that name (FALLBACK_CANDIDATES),
# and install_core's language list counts it as a CJK font.
#
# An installed system that speaks Japanese gets the whole font: the
# installer adds the fonts-cjk package from the medium's repository.
#
# Run it again whenever a Japanese catalogue changes; distro/live/build.sh
# refuses to build when a character of distro/locale/ja is missing from the
# subset. fontTools is not on the build host by default: a virtualenv with
# `pip install fonttools` is enough. The font is under the SIL Open Font
# License 1.1, which allows a modified (subset) copy under the same licence;
# the licence travels beside it.
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SRC = sys.argv[1] if len(sys.argv) > 1 else '/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc'
OUT = os.path.join(HERE, 'root/usr/share/fonts/palm-live/NotoSansCJKjp-Regular.otf')
LICENSE_SRC = '/usr/share/licenses/noto-fonts-cjk/LICENSE'
LICENSE_OUT = os.path.join(HERE, 'root/usr/share/licenses/palmframe-live/NotoSansCJK-OFL.txt')

RANGES = [
    (0x0020, 0x007E),  # ASCII, so the face is a whole font on its own
    (0x3000, 0x303F),  # CJK symbols and punctuation
    (0x3040, 0x309F),  # hiragana
    (0x30A0, 0x30FF),  # katakana
    (0xFF00, 0xFFEF),  # half-width and full-width forms
]


def wanted(ranges=True):
    cps = set()
    for lo, hi in (RANGES if ranges else []):
        cps.update(range(lo, hi + 1))
    d = os.path.join(ROOT, 'distro/locale/ja')
    for name in sorted(os.listdir(d)):
        if name.endswith('.msg'):
            with open(os.path.join(d, name), encoding='utf-8') as f:
                cps.update(ord(c) for c in f.read() if ord(c) >= 0x20)
    return cps


def check(font):
    # Every CJK character the catalogues use must be in the font; Latin and
    # the rest come from the base fonts, so they are not asked of it. The
    # font's coverage comes from fontconfig, which every build host has.
    out = subprocess.run(['fc-query', '--format', '%{charset}', font], capture_output=True, text=True, check=True).stdout
    have = set()
    for part in out.split():
        lo, _, hi = part.partition('-')
        have.update(range(int(lo, 16), int(hi or lo, 16) + 1))
    missing = sorted(c for c in wanted(ranges=False) if c >= 0x2E80 and c not in have)
    if missing:
        print('subset-cjk: %s lacks %d characters of distro/locale/ja (%s); run distro/live/subset-cjk.py again'
              % (font, len(missing), ''.join(chr(c) for c in missing[:20])), file=sys.stderr)
        return 1
    return 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == '--check':
        return check(sys.argv[2])
    from fontTools import subset
    cps = wanted()
    opts = subset.Options()
    opts.font_number = 0  # the collection's first face is Japanese
    opts.layout_features = []  # palmy shapes CJK without OpenType features
    opts.hinting = False
    opts.name_IDs = ['*']
    opts.notdef_outline = True
    font = subset.load_font(SRC, opts)
    s = subset.Subsetter(opts)
    s.populate(unicodes=sorted(cps))
    s.subset(font)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    subset.save_font(font, OUT, opts)
    if os.path.exists(LICENSE_SRC):
        os.makedirs(os.path.dirname(LICENSE_OUT), exist_ok=True)
        with open(LICENSE_SRC, 'rb') as a, open(LICENSE_OUT, 'wb') as b:
            b.write(a.read())
    have = set(font.getBestCmap())
    print('%s: %d characters asked, %d in the font, %d bytes' % (OUT, len(cps), len(have & cps), os.path.getsize(OUT)))


if __name__ == '__main__':
    sys.exit(main())
