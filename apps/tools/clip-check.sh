#!/usr/bin/env bash
# The X11 clipboard against owners and readers that are not palmy, and
# selections bigger than one request (INCR), on a private Xvfb + openbox.
#
#   clip-check.sh
#
# For each size (4 KiB, 1 MiB, 6 MiB of text): palmy owns it and xclip, xsel
# and a second palmy read it; then xclip owns it, then xsel, and palmy reads
# it. Every transfer is checked by length and FNV-1a hash. PALMY_TRACE_CLIP=1
# shows which went by INCR. PALMY_ROOT=<checkout> builds another tree's palmy.
# Needs xclip, xsel, Xvfb, openbox, python3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="${PALMY_ROOT:-$(cd "$HERE/../.." && pwd)}"
ODIN="${ODIN:-$(command -v odin || echo "$HOME/.local/share/mise/installs/odin/dev-2026-09/odin")}"
TMP="$(mktemp -d /tmp/palmy-clip-XXXXXX)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
for t in xclip xsel xprop Xvfb openbox python3; do command -v $t >/dev/null || { echo "missing $t"; exit 1; }; done

"$ODIN" build "$HERE/clip-check" -collection:palmy="$R/palmy" -out:"$TMP/clip-check" || exit 1
CC="$TMP/clip-check"

n=70; while [ -e /tmp/.X11-unix/X$n ] || [ -e /tmp/.X$n-lock ]; do n=$((n+1)); done
Xvfb :$n -screen 0 800x600x24 -nolisten tcp >/dev/null 2>&1 & PIDS+=($!)
for _ in $(seq 1 50); do [ -e /tmp/.X11-unix/X$n ] && break; sleep 0.1; done
export DISPLAY=:$n PALMY_BACKEND=x11
unset WAYLAND_DISPLAY
openbox --sm-disable >/dev/null 2>&1 & PIDS+=($!)
# A window opened before the window manager is up can wait for a map that
# never comes; wait until openbox has announced itself.
for _ in $(seq 1 50); do
  xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q "window id" && break
  sleep 0.1
done
# openbox announces itself a moment before it handles map requests: a window
# mapped in that moment is never mapped (measured: 1 in 16 fresh servers,
# whatever the timeout). Let it settle.
sleep 1

fnv() { python3 -c 'import sys
h=0xcbf29ce484222325
for b in open(sys.argv[1],"rb").read(): h=((h^b)*0x100000001b3)&0xffffffffffffffff
print("%d %x"%(len(open(sys.argv[1],"rb").read()),h))' "$1"; }

pass=0; fail=0
check() { # check <label> <expected "len hash"> <got "len hash">
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1 ($3)"; else fail=$((fail+1)); echo "  FAIL $1: want '$2' got '$3'"; fi
}

for size in 4096 1048576 6291456; do
  f="$TMP/data-$size.txt"
  head -c $((size * 3 / 4)) /dev/urandom | base64 -w 76 | head -c $size > "$f"
  want="$(fnv "$f")"
  echo "== $size bytes"

  # palmy owns it.
  "$CC" set "$f" 30 > "$TMP/owner.log" 2>>"$TMP/trace" & OWNER=$!; PIDS+=($OWNER)
  for _ in $(seq 1 50); do grep -q OWNED "$TMP/owner.log" && break; sleep 0.1; done
  grep -q OWNED "$TMP/owner.log" || echo "  (palmy did not take the selection: $(cat "$TMP/owner.log"))"
  timeout 20 xclip -o -selection clipboard > "$TMP/out" 2>/dev/null; check "palmy -> xclip" "$want" "$(fnv "$TMP/out")"
  timeout 20 xsel --clipboard --output > "$TMP/out" 2>/dev/null; check "palmy -> xsel" "$want" "$(fnv "$TMP/out")"
  got="$("$CC" get 2>>"$TMP/trace" | sed -n 's/^GOT //p')"; check "palmy -> palmy" "$want" "$got"
  kill $OWNER 2>/dev/null; wait $OWNER 2>/dev/null

  # xclip owns it.
  xclip -i -selection clipboard < "$f"; sleep 0.3
  got="$("$CC" get 2>>"$TMP/trace" | sed -n 's/^GOT //p')"; check "xclip -> palmy" "$want" "$got"

  # xsel owns it.
  xsel --clipboard --input < "$f"; sleep 0.3
  got="$("$CC" get 2>>"$TMP/trace" | sed -n 's/^GOT //p')"; check "xsel -> palmy" "$want" "$got"
  # Clearing it makes whichever of xclip and xsel still owns it let go and exit.
  xsel --clipboard --clear 2>/dev/null
done

echo "== a watcher sees other owners' selections and reads them, INCR included"
big="$TMP/data-1048576.txt"; small="$TMP/data-4096.txt"
"$CC" watch 12 > "$TMP/watch.log" 2>>"$TMP/trace" & W=$!; PIDS+=($W)
for _ in $(seq 1 50); do grep -q '^WATCH' "$TMP/watch.log" && break; sleep 0.1; done
sleep 0.5
xsel --clipboard --input < "$big"; sleep 1.5
xclip -i -selection clipboard < "$small"; sleep 1.5
kill $W 2>/dev/null; wait $W 2>/dev/null
xsel --clipboard --clear 2>/dev/null; sleep 0.2
grep -q '^WATCH Always' "$TMP/watch.log" && { pass=$((pass+1)); echo "  ok   watch mode Always (XFIXES)"; } || { fail=$((fail+1)); echo "  FAIL watch mode: $(head -1 "$TMP/watch.log")"; }
for f in "$big" "$small"; do
  w="$(fnv "$f")"
  if grep -q "^OFFER .* $w None" "$TMP/watch.log"; then pass=$((pass+1)); echo "  ok   watched offer read ($w)"; else fail=$((fail+1)); echo "  FAIL watched offer $w not seen:"; cat "$TMP/watch.log"; fi
done

[ -n "${PALMY_TRACE_CLIP:-}" ] && { echo "== palmy's trace"; cat "$TMP/trace"; }
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
