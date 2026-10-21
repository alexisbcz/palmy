# Test fixtures for the image protocols, and where each came from.
#
#   foot-gradient.six   img2sixel (libsixel 1.10.3) of gradient.png, rendered by
#                       foot 1.16.2 as the Sixel oracle.
#   gradient.png        convert -size 64x48 gradient:red-blue -fill yellow
#                       -draw "rectangle 8,8 24,24" (a 16-bit RGB PNG).
#   icat-*.esc          what `kitten icat` (kitty 0.32.2) wrote, captured through
#                       script(1): --transfer-mode=stream, --place 10x5@40x2,
#                       and -z -1. kitty itself is the oracle for these.
#   rose.six            img2sixel of `convert rose: -resize 300%` (ImageMagick's
#                       built-in photograph), for the screenshots.
#   logo.png            `convert logo: -resize 260x -strip`, for the screenshots.
#   rgba8.png           convert -size 16x8 xc:"rgba(0,128,255,0.5)" -fill
#                       "rgba(255,255,0,1)" -draw "rectangle 0,0 3,3" PNG32:
#                       (8-bit RGBA, half transparent).
#
# This script writes the other two:
#
#   kitty-rgba-zlib.esc a 16x16 RGBA image, zlib-compressed and sent in two
#                       chunks under id 7. kitty answers `i=7;OK`.
#   zlib-bomb.esc       64 MiB of zeros, compressed to 65 KB, sent as a chunked
#                       RGBA transmission that claims to be 100x100. A decoder
#                       without a cap inflates all 64 MiB; ours must stop at
#                       the budget and answer with an error.
import base64, zlib


def apc(ctrl, payload=b""):
    return b"\x1b_G" + ctrl.encode() + (b";" + payload if payload else b"") + b"\x1b\\"


px = bytearray()
for y in range(16):
    for x in range(16):
        px += bytes([0, 200, 0, 255]) if x < 8 else bytes([255, 0, 0, 128])
z = base64.b64encode(zlib.compress(bytes(px)))
half = len(z) // 2 // 4 * 4
open("kitty-rgba-zlib.esc", "wb").write(
    apc("a=T,f=32,s=16,v=16,i=7,o=z,m=1", z[:half]) + apc("m=0", z[half:])
)

z = base64.b64encode(zlib.compress(b"\0" * (64 << 20), 9))
out = b""
for i in range(0, len(z), 4096):
    more = 1 if i + 4096 < len(z) else 0
    ctrl = "a=T,f=32,s=100,v=100,i=77,o=z,m=%d" % more if i == 0 else "m=%d" % more
    out += apc(ctrl, z[i : i + 4096])
open("zlib-bomb.esc", "wb").write(out)
