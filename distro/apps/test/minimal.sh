#!/usr/bin/env bash
# Run palmy applications inside a root filesystem shaped like Palmframe's,
# against a compositor that offers only the mandatory Wayland globals, and
# keep a screenshot of each.
#
# The root is what the target has and nothing more: glibc, busybox, the fonts
# in fonts.list, the binaries under test, an empty $HOME with no ~/.config, no
# LANG, no fontconfig, no D-Bus. It is entered with a rootless user namespace
# and chroot, so nothing on the host is visible to the application -- a font,
# a library or a helper binary the app reaches for and Palmframe does not ship
# shows up here as a failure rather than as a silent dependency on the build
# machine. The compositor is stubwl.py; see its header for what it leaves out.
#
#   distro/apps/test/minimal.sh calc term files       these apps
#   distro/apps/test/minimal.sh                       the default install set
#                                                     (default.list, minus the session)
#   XKB=1 distro/apps/test/minimal.sh calc            also ship libxkbcommon and
#                                                     send a real keymap
#   TYPE='12+30=' distro/apps/test/minimal.sh calc    type into the window
#   EMOJI=1 distro/apps/test/minimal.sh               also install the emoji set
#
# Output: distro/build/apps/shots/<app>.png and <app>.log, and one line per
# application on stdout: app, frames committed, exit status.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APPS_DIR="$(dirname "$HERE")"
DISTRO="$(dirname "$APPS_DIR")"
ROOT="$(dirname "$DISTRO")"
BIN="$DISTRO/out/bin"
WORK="$DISTRO/build/apps"
RFS="$WORK/rootfs"
SHOTS="$WORK/shots"
SECONDS_PER_APP="${SECONDS_PER_APP:-4}"
mkdir -p "$SHOTS"

if [ "$#" -gt 0 ]; then
	apps=("$@")
else
	# wm and greeter are the session, and need the real window manager.
	apps=($(grep -v '^#' "$APPS_DIR/default.list" | grep -vxE 'wm|greeter'))
fi

# -- the root ------------------------------------------------------------------
rm -rf "$RFS"
mkdir -p "$RFS"/{usr/bin,usr/lib,etc,home/palm,tmp,proc,sys,dev,run/user/1000}
ln -s usr/bin "$RFS/bin"
ln -s usr/bin "$RFS/sbin"
ln -s usr/lib "$RFS/lib"
ln -s usr/lib "$RFS/lib64"
ln -s lib "$RFS/usr/lib64"
chmod 700 "$RFS/run/user/1000"
for lib in ld-linux-x86-64.so.2 libc.so.6 libm.so.6; do
	cp -L "/usr/lib/$lib" "$RFS/usr/lib/"
done
if [ "${XKB:-0}" = 1 ]; then
	cp -L /usr/lib/libxkbcommon.so.0 "$RFS/usr/lib/"
fi
cp "$DISTRO/out/busybox" "$RFS/usr/bin/busybox"
for a in sh ls cat env; do ln -s busybox "$RFS/usr/bin/$a"; done
echo "palm:x:1000:1000:palm:/home/palm:/bin/sh" >"$RFS/etc/passwd"
grep -v '^\s*#' "$APPS_DIR/fonts.list" | while read -r src dst set; do
	[ -n "$src" ] || continue
	[ "$set" = base ] || [ "${EMOJI:-0}" = 1 ] || continue
	case "$src" in /*) ;; *) src="$ROOT/$src" ;; esac
	mkdir -p "$RFS$(dirname "$dst")"
	cp "$src" "$RFS$dst"
done
mkdir -p "$RFS/usr/share/applications"
for a in "${apps[@]}"; do
	[ -f "$BIN/$a" ] && cp "$BIN/$a" "$RFS/usr/bin/"
	[ -f "$APPS_DIR/desktop/$a.desktop" ] && cp "$APPS_DIR/desktop/$a.desktop" "$RFS/usr/share/applications/"
done

KEYMAP_ARGS=()
if [ "${XKB:-0}" = 1 ]; then
	xkbcli compile-keymap --layout us >"$WORK/us.xkb"
	KEYMAP_ARGS=(--keymap "$WORK/us.xkb")
fi

# -- each application ------------------------------------------------------------
for a in "${apps[@]}"; do
	if [ ! -f "$RFS/usr/bin/$a" ]; then
		printf '%s\tmissing\n' "$a"
		continue
	fi
	sock="$RFS/run/user/1000/wayland-stub"
	rm -f "$sock" # or the wait below sees the last run's socket
	python3 -I "$HERE/stubwl.py" --socket "$sock" --png "$SHOTS/$a.png" \
		--seconds "$SECONDS_PER_APP" --type "${TYPE:-}" "${KEYMAP_ARGS[@]}" \
		$(case "$a" in launcher | greeter) echo --layer-shell ;; esac) \
		>"$SHOTS/$a.stub.log" 2>&1 &
	stub=$!
	for _ in $(seq 50); do [ -S "$sock" ] && break; sleep 0.05; done
	rm -f "$SHOTS/$a.png"
	# /proc, /sys and /dev are the host's, bound in: the target mounts all
	# three before anything runs, and Odin's core:os resolves paths through
	# /proc, so without it every open fails and that is not what is being
	# tested.
	timeout -k 1 "$((SECONDS_PER_APP + 1))" unshare -rm sh -c '
		r=$1; shift
		for d in proc sys dev; do mount --rbind /$d "$r/$d"; done
		exec chroot "$r" "$@"' _ "$RFS" /usr/bin/env -i \
		HOME=/home/palm USER=palm PATH=/usr/bin \
		XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-stub \
		"/usr/bin/$a" >"$SHOTS/$a.log" 2>&1
	status=$?
	wait "$stub"
	frames=$(sed -n 's/^stubwl: \([0-9]*\) frames.*/\1/p' "$SHOTS/$a.stub.log")
	printf '%s\tframes=%s\texit=%s\n' "$a" "${frames:-0}" "$status"
done
