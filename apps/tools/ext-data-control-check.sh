#!/usr/bin/env bash
# palmy's clipboard watcher against a real ext_data_control_v1.
#
#   ext-data-control-check.sh
#
# No packaged compositor here offers ext_data_control_v1: it arrived in
# wlroots 0.19, and Ubuntu 24.04 ships 0.17 (sway 1.9, labwc 0.7, wayfire
# 0.8); mutter, weston and KWin 5.27 have no data control at all. So this
# builds the smallest compositor that has it: wayland 1.23.1, pixman 0.44.2
# and wlroots 0.19.0 from their release tarballs into $PALMY_EXTDC (default
# ~/.cache/palmy-extdc), and wlroots' own tinywl with two lines added -- the
# primary selection and ext_data_control_v1 managers. It advertises no
# zwlr_data_control, so whatever palmy watches with is the ext protocol.
#
# Then: palmy's clip-check watches the clipboard, apps/tools/wl-ext-copy.py
# sets it through ext_data_control_v1 (40 bytes, then 1 MiB), and every offer
# palmy reports must carry the owner's types and read back byte for byte.
# Needs network access once (downloads), meson, ninja, a C compiler, python3.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
R="$(cd "$HERE/../.." && pwd)"
ODIN="${ODIN:-$(command -v odin || echo "$HOME/.local/share/mise/installs/odin/dev-2026-09/odin")}"
D="${PALMY_EXTDC:-$HOME/.cache/palmy-extdc}"
P="$D/prefix"
export PKG_CONFIG_PATH="$P/lib/pkgconfig:$P/lib/$(gcc -dumpmachine)/pkgconfig:$P/share/pkgconfig"
LIBDIR="$P/lib/$(gcc -dumpmachine)"

build() {
  mkdir -p "$D" && cd "$D" || exit 1
  get() { [ -f "$2" ] || curl -sSLf -o "$2" "$1" || { echo "cannot download $1"; exit 1; }; }
  get https://gitlab.freedesktop.org/wayland/wayland/-/releases/1.23.1/downloads/wayland-1.23.1.tar.xz wayland.tar.xz
  get https://www.cairographics.org/releases/pixman-0.44.2.tar.gz pixman.tar.gz
  get https://gitlab.freedesktop.org/wlroots/wlroots/-/releases/0.19.0/downloads/wlroots-0.19.0.tar.gz wlroots.tar.gz
  for t in wayland.tar.xz pixman.tar.gz wlroots.tar.gz; do tar xf "$t"; done
  (cd wayland-1.23.1 && meson setup build --prefix="$P" -Ddocumentation=false -Dtests=false --wipe && ninja -C build install) >"$D/build.log" 2>&1 || { echo "wayland build failed: $D/build.log"; exit 1; }
  (cd pixman-0.44.2 && meson setup build --prefix="$P" -Dtests=disabled -Ddemos=disabled --wipe && ninja -C build install) >>"$D/build.log" 2>&1 || { echo "pixman build failed"; exit 1; }
  (cd wlroots-0.19.0 && meson setup build --prefix="$P" --wipe -Dxwayland=disabled -Dbackends= -Drenderers= \
     -Dallocators= -Dsession=disabled -Dexamples=false -Dcolor-management=disabled -Dlibliftoff=disabled \
     -Dxcb-errors=disabled && ninja -C build install) >>"$D/build.log" 2>&1 || { echo "wlroots build failed"; exit 1; }
  mkdir -p extdc && cd extdc
  cp ../wlroots-0.19.0/tinywl/tinywl.c .
  python3 - <<'PY'
s = open("tinywl.c").read()
s = s.replace("#include <wlr/types/wlr_data_device.h>",
    "#include <wlr/types/wlr_data_device.h>\n#include <wlr/types/wlr_ext_data_control_v1.h>\n#include <wlr/types/wlr_primary_selection_v1.h>", 1)
s = s.replace("\twlr_data_device_manager_create(server.wl_display);",
    "\twlr_data_device_manager_create(server.wl_display);\n\twlr_primary_selection_v1_device_manager_create(server.wl_display);\n\twlr_ext_data_control_manager_v1_create(server.wl_display, 1);", 1)
open("tinywl.c", "w").write(s)
PY
  "$(pkg-config --variable=wayland_scanner wayland-scanner)" server-header \
    "$(pkg-config --variable=pkgdatadir wayland-protocols)/stable/xdg-shell/xdg-shell.xml" xdg-shell-protocol.h
  cc -DWLR_USE_UNSTABLE -I. $(pkg-config --cflags wlroots-0.19 wayland-server xkbcommon) tinywl.c \
     $(pkg-config --libs wlroots-0.19 wayland-server xkbcommon) -Wl,-rpath,"$LIBDIR" -o tinywl >>"$D/build.log" 2>&1 ||
     { echo "tinywl build failed"; exit 1; }
}
[ -x "$D/extdc/tinywl" ] || build
cd "$R"

TMP="$(mktemp -d /tmp/palmy-extdc-XXXXXX)"
PIDS=()
cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT
"$ODIN" build "$HERE/clip-check" -collection:palmy="$R/palmy" -out:"$TMP/clip-check" || exit 1

export XDG_RUNTIME_DIR="$TMP" LD_LIBRARY_PATH="$LIBDIR"
unset WAYLAND_DISPLAY DISPLAY
WLR_BACKENDS=headless WLR_RENDERER=pixman "$D/extdc/tinywl" > "$TMP/comp.log" 2>&1 & PIDS+=($!)
for _ in $(seq 1 50); do sock=$(ls "$TMP" | grep -m1 '^wayland-[0-9]*$'); [ -n "$sock" ] && break; sleep 0.1; done
export WAYLAND_DISPLAY="$sock"

head -c 1048576 /dev/urandom | base64 -w 76 | head -c 1048576 > "$TMP/big.txt"
printf 'small selection over ext_data_control_v1' > "$TMP/small.txt"
fnv() { python3 -c 'import sys
d=open(sys.argv[1],"rb").read(); h=0xcbf29ce484222325
for b in d: h=((h^b)*0x100000001b3)&0xffffffffffffffff
print("%d %x"%(len(d),h))' "$1"; }

"$TMP/clip-check" watch 9 > "$TMP/watch.log" 2>&1 & W=$!; PIDS+=($W)
for _ in $(seq 1 50); do grep -q '^WATCH' "$TMP/watch.log" && break; sleep 0.1; done
python3 "$HERE/wl-ext-copy.py" "$TMP/small.txt" 2 > "$TMP/copy1.log" 2>&1
python3 "$HERE/wl-ext-copy.py" "$TMP/big.txt" 3 > "$TMP/copy2.log" 2>&1
sleep 0.5
kill $W 2>/dev/null; wait $W 2>/dev/null
cat "$TMP/watch.log"

pass=0; fail=0
python3 "$HERE/wl-ext-copy.py" --globals > "$TMP/globals.txt"
if grep -q '^ext_data_control_manager_v1 ' "$TMP/globals.txt" && ! grep -q '^zwlr_data_control' "$TMP/globals.txt"; then
  pass=$((pass+1)); echo "the compositor offers ext_data_control_manager_v1 and no zwlr_data_control"
else fail=$((fail+1)); echo "FAIL: unexpected globals:"; cat "$TMP/globals.txt"; fi
grep -q '^WATCH Always' "$TMP/watch.log" && pass=$((pass+1)) || { fail=$((fail+1)); echo "FAIL: palmy did not watch through data control"; }
for f in small big; do
  want="$(fnv "$TMP/$f.txt")"
  if grep -q "^OFFER \[\"text/plain;charset=utf-8\".* $want None" "$TMP/watch.log"; then pass=$((pass+1));
  else fail=$((fail+1)); echo "FAIL: the $f selection ($want) was not read back"; fi
done
echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
