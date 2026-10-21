#!/usr/bin/env bash
# The image protocols against real terminals.
#
#   apps/term/oracle/images/run.sh [workdir]
#
# Runs the same probe in foot (Sixel), in kitty (the Kitty graphics protocol)
# and in this terminal, each on a private headless sway that nothing can see,
# and compares: the replies, where the cursor ends up after every image, and
# a block of pixels of the image as each terminal drew it. Needs foot, kitty
# (software GL is enough), sway, grim and ImageMagick; nothing here touches
# the person's own session.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
TD="$ROOT/apps/term/testdata"
W="${1:-$(mktemp -d /tmp/term-image-oracle-XXXXXX)}"
mkdir -p "$W"
ODIN="${ODIN:-odin}"
command -v "$ODIN" >/dev/null || ODIN="$HOME/.local/share/mise/installs/odin/dev-2026-09/odin"

"$ODIN" build "$ROOT/apps/term" -collection:palmy="$ROOT/palmy" -collection:kit="$ROOT/apps/kit" \
  -collection:shadcn="$ROOT/shadcn" -out:"$W/term.bin" || exit 1

# shot OUT SECONDS CMD...: a terminal on a private headless compositor, photographed.
shot() {
  local out="$1" secs="$2"; shift 2
  export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local tmp; tmp="$(mktemp -d /tmp/term-oracle-sway-XXXXXX)"
  printf 'output HEADLESS-1 resolution 1000x640\ndefault_border none\n' > "$tmp/sway.conf"
  echo "exec printf '%s' \"\$WAYLAND_DISPLAY\" > $tmp/display" >> "$tmp/sway.conf"
  env -u WAYLAND_DISPLAY -u DISPLAY WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman \
    sway -c "$tmp/sway.conf" > "$tmp/sway.log" 2>&1 &
  local sway=$! wd=""
  for _ in $(seq 1 80); do sleep 0.1; wd="$(cat "$tmp/display" 2>/dev/null)"; [ -n "$wd" ] && break; done
  WAYLAND_DISPLAY="$wd" LIBGL_ALWAYS_SOFTWARE=1 "$@" > "$tmp/app.log" 2>&1 &
  local app=$!
  disown $app
  sleep "$secs"
  WAYLAND_DISPLAY="$wd" grim "$out"
  kill $app 2>/dev/null; sleep 0.3; kill -9 $app 2>/dev/null
  kill $sway; wait $sway 2>/dev/null
  rm -rf "$tmp"
}

SIXEL_ITEMS=("@A\r\nxyz" "$TD/foot-gradient.six" "@B")
KITTY_ITEMS=("@A\r\nxyz" "$TD/icat-stream.esc" "@B" "$TD/kitty-rgba-zlib.esc" "@C" "$TD/icat-z.esc" "@zz" "$TD/icat-place.esc" "@E")

echo "== Sixel: foot"
shot "$W/foot.png" 4 foot -e python3 -I "$HERE/probe.py" "$W/foot.txt" "${SIXEL_ITEMS[@]}"
echo "== Kitty graphics: kitty"
shot "$W/kitty.png" 8 kitty -o font_size=10 -o background=#0b1120 python3 -I "$HERE/probe.py" "$W/kitty.txt" "${KITTY_ITEMS[@]}"
echo "== this terminal"
HOLD=0.5 "$W/term.bin" run --timeout 30 --png "$W/ours-sixel.png" --rows 14 --cols 60 -- \
  python3 -I "$HERE/probe.py" "$W/ours-sixel.txt" "${SIXEL_ITEMS[@]}" > /dev/null
HOLD=0.5 "$W/term.bin" run --timeout 30 --png "$W/ours-kitty.png" --rows 14 --cols 60 -- \
  python3 -I "$HERE/probe.py" "$W/ours-kitty.txt" "${KITTY_ITEMS[@]}" > /dev/null

# The cursor positions depend on the cell size, which differs between the
# terminals; the replies and the positions after the Kitty images do not, for
# these images, and are compared outright. The Sixel position is compared in
# rows of the image, which is what foot's rule is about.
fail=0
echo "== replies and cursor positions, kitty vs this terminal"
if diff <(tail -n +2 "$W/kitty.txt") <(tail -n +2 "$W/ours-kitty.txt"); then
  echo "identical ($(($(wc -l < "$W/kitty.txt") - 1)) probes)"
else
  fail=1
fi
echo "== Sixel"
cat "$W/foot.txt"; cat "$W/ours-sixel.txt"
echo "== pixels"
python3 -I "$HERE/compare_block.py" "$W/kitty.png" "$W/ours-kitty.png" 64 48 || fail=1
python3 -I "$HERE/compare_block.py" "$W/foot.png" "$W/ours-sixel.png" 64 36 || fail=1
echo "screenshots and logs in $W"
exit $fail
