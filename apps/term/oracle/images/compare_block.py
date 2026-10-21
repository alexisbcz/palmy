# compare_block.py A.png B.png W H: find the first strongly red pixel in each
# screenshot (the top left corner of the test image, which starts red) and
# compare the W x H block from there, pixel by pixel. Exits non-zero when
# any channel differs by more than 2.
import subprocess, sys


def load(p):
    w, h = map(int, subprocess.check_output(["identify", "-format", "%w %h", p]).split())
    return w, h, subprocess.check_output(["convert", p, "-depth", "8", "rgb:-"])


def corner(img):
    w, h, raw = img
    for y in range(h):
        for x in range(w):
            o = (y * w + x) * 3
            if raw[o] > 200 and raw[o + 1] < 40 and raw[o + 2] < 40:
                return x, y
    return None


A, B = load(sys.argv[1]), load(sys.argv[2])
W, H = int(sys.argv[3]), int(sys.argv[4])
pa, pb = corner(A), corner(B)
if pa is None or pb is None:
    print("no image found:", sys.argv[1] if pa is None else sys.argv[2])
    sys.exit(1)
bad = worst = 0
for y in range(H):
    for x in range(W):
        oa = ((pa[1] + y) * A[0] + pa[0] + x) * 3
        ob = ((pb[1] + y) * B[0] + pb[0] + x) * 3
        d = max(abs(A[2][oa + i] - B[2][ob + i]) for i in range(3))
        worst = max(worst, d)
        bad += d > 2
print(f"{sys.argv[1].split('/')[-1]} vs {sys.argv[2].split('/')[-1]}: {W}x{H} block, "
      f"{bad} pixels differ by more than 2 levels, largest difference {worst}")
sys.exit(1 if bad else 0)
