#!/bin/sh
# qemu-test.sh — boot the window manager on (virtual) bare metal and look.
#
# The bare-metal backend must never run on the host: the host is somebody's
# live desktop. So the only place `wm --drm` executes is here, inside QEMU,
# from a throwaway initramfs this script assembles out of the static busybox,
# the host's glibc, a few fonts, wm and term:
#
#   apps/wm/qemu-test.sh                 build, boot, run the default script
#   apps/wm/qemu-test.sh --root          the same, with wm running as root
#   apps/wm/qemu-test.sh --kiosk         wm --drm --kiosk --exec term
#   apps/wm/qemu-test.sh --no-xkb        no /usr/share/X11/xkb: the built-in keymap
#   apps/wm/qemu-test.sh --wm-args "..."  run wm with these arguments instead
#   apps/wm/qemu-test.sh --sigterm-after N   (as root) SIGTERM wm after N s
#   apps/wm/qemu-test.sh --interactive   boot with a GTK window and stop there
#   apps/wm/qemu-test.sh -- <steps>      replace the default QMP script
#
# The steps are qemu-qmp.py's (wait:, shot:, type:, key:, move:, click:,
# until:). The default script waits for the desktop, takes a screenshot,
# types `echo hello` into term, moves the virtio-tablet pointer, clicks, and
# takes screenshots after each. Everything lands in distro/build/wm/:
# serial.log is the guest's console (wm's own stdout and stderr included),
# *.png the screendumps.
#
# By default wm runs as user `palm` (uid 1000) in groups video and input,
# which is how palm-login starts a session; /dev/dri and /dev/input get the
# ownership palm-init gives them.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
OUT="$ROOT/distro/build/wm"
STAGE="$OUT/root"
KERNEL="$ROOT/distro/out/bzImage"
BUSYBOX="$ROOT/distro/out/busybox"
QMP="$OUT/qmp.sock"
SERIAL="$OUT/serial.log"

as_user=1
kiosk=0
xkb=1
interactive=0
timeout_s=120
wm_args=""
sigterm_after=0
while [ $# -gt 0 ]; do
	case "$1" in
	--root) as_user=0 ;;
	--kiosk) kiosk=1 ;;
	--no-xkb) xkb=0 ;;
	--interactive) interactive=1 ;;
	--timeout) timeout_s=$2; shift ;;
	--wm-args) wm_args=$2; shift ;;
	--sigterm-after) sigterm_after=$2; as_user=0; shift ;;
	--) shift; break ;;
	*) echo "qemu-test: unknown option $1" >&2; exit 2 ;;
	esac
	shift
done

[ -f "$KERNEL" ] || { echo "qemu-test: no $KERNEL (distro/kernel/build.sh)" >&2; exit 1; }
[ -x "$BUSYBOX" ] || { echo "qemu-test: no $BUSYBOX (distro/busybox/build.sh)" >&2; exit 1; }
mkdir -p "$OUT"

# --- build ------------------------------------------------------------------
cd "$ROOT"
COLL="-collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn"
echo "qemu-test: building wm, term and launcher"
odin build apps/wm $COLL -o:speed -out:"$OUT/wm.bin"
for app in term launcher; do
	[ -d "apps/$app" ] || continue
	if [ ! -x "$OUT/$app" ] || [ -n "$(find "apps/$app" palmy apps/kit shadcn -name '*.odin' -newer "$OUT/$app" | head -1)" ]; then
		odin build "apps/$app" $COLL -o:speed -out:"$OUT/$app"
	fi
done

# --- stage ------------------------------------------------------------------
rm -rf "$STAGE"
mkdir -p "$STAGE"/usr/bin "$STAGE"/usr/lib "$STAGE"/etc "$STAGE"/proc "$STAGE"/sys \
	"$STAGE"/dev "$STAGE"/run "$STAGE"/tmp "$STAGE"/home/palm "$STAGE"/root \
	"$STAGE"/usr/share/fonts/TTF "$STAGE"/usr/share/fonts/palmy
ln -s usr/bin "$STAGE/bin"
ln -s usr/bin "$STAGE/sbin"
ln -s usr/lib "$STAGE/lib"
ln -s usr/lib "$STAGE/lib64"

cp "$BUSYBOX" "$STAGE/usr/bin/busybox"
for a in $("$BUSYBOX" --list); do
	[ -e "$STAGE/usr/bin/$a" ] || ln -s busybox "$STAGE/usr/bin/$a"
done
cp "$OUT/wm.bin" "$STAGE/usr/bin/wm"
cp "$OUT/term" "$STAGE/usr/bin/term"
[ -x "$OUT/launcher" ] && cp "$OUT/launcher" "$STAGE/usr/bin/launcher" || true

for l in libc.so.6 libm.so.6 libxkbcommon.so.0; do
	cp -L "/usr/lib/$l" "$STAGE/usr/lib/$l"
done
cp -L /usr/lib64/ld-linux-x86-64.so.2 "$STAGE/usr/lib/ld-linux-x86-64.so.2"

for f in DejaVuSans.ttf DejaVuSans-Bold.ttf DejaVuSansMono.ttf DejaVuSansMono-Bold.ttf; do
	[ -f "/usr/share/fonts/TTF/$f" ] && cp "/usr/share/fonts/TTF/$f" "$STAGE/usr/share/fonts/TTF/"
done
# Geist where the distribution puts it, and where apps/kit still looks for it
# (kit.FONT_DIR is a path into this checkout; see distro/notes/wm.md).
cp parity/web/public/fonts/Geist-*.ttf "$STAGE/usr/share/fonts/palmy/"
KITFONTS="$STAGE$ROOT/parity/web/public/fonts"
mkdir -p "$KITFONTS"
cp parity/web/public/fonts/Geist-*.ttf "$KITFONTS/"

if [ "$xkb" = 1 ] && [ -d /usr/share/X11/xkb ]; then
	mkdir -p "$STAGE/usr/share/X11"
	cp -rL /usr/share/X11/xkb "$STAGE/usr/share/X11/xkb"
fi

cat > "$STAGE/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
palm:x:1000:1000:palm:/home/palm:/bin/sh
EOF
cat > "$STAGE/etc/group" <<'EOF'
root:x:0:
tty:x:5:
wheel:x:10:palm
video:x:39:palm
audio:x:63:palm
input:x:97:palm
palm:x:1000:
EOF

WMARGS="--drm --exec term"
[ "$kiosk" = 1 ] && WMARGS="--drm --kiosk --exec term"
[ -n "$wm_args" ] && WMARGS="$wm_args"

cat > "$STAGE/init" <<EOF
#!/bin/sh
# Throwaway init for apps/wm/qemu-test.sh. Not palm-init: just enough of what
# palm-init does (mounts, device ownership, XDG_RUNTIME_DIR) to start a
# session the way palm-login will.
export PATH=/usr/bin
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev 2>/dev/null
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts
mount -t tmpfs shm /dev/shm
mount -t tmpfs run /run
mount -t tmpfs tmp /tmp
chmod 1777 /tmp
echo "init: waiting for /dev/dri/card0"
i=0; while [ ! -e /dev/dri/card0 ] && [ \$i -lt 50 ]; do sleep 0.1; i=\$((i+1)); done
chown root:video /dev/dri/*; chmod 0660 /dev/dri/*
chown root:input /dev/input/event*; chmod 0660 /dev/input/event*
ls -l /dev/dri /dev/input
for d in /sys/class/input/event*; do
	echo "input: \$d \$(cat \$d/device/name) ev=\$(cat \$d/device/capabilities/ev) key=\$(cat \$d/device/capabilities/key) abs=\$(cat \$d/device/capabilities/abs) rel=\$(cat \$d/device/capabilities/rel) prop=\$(cat \$d/device/properties)"
done
mkdir -p /run/user/1000 /run/user/0
chown palm:palm /run/user/1000 /home/palm; chmod 0700 /run/user/1000 /run/user/0
ENVS="HOME=/home/palm USER=palm SHELL=/bin/sh PATH=/usr/bin XDG_RUNTIME_DIR=/run/user/1000 XDG_SESSION_TYPE=wayland PALMY_WM_DRM_DEBUG=1"
if [ $as_user = 1 ]; then
	echo "init: starting wm $WMARGS as palm (\$(id palm))"
	su -s /bin/sh palm -c "env \$ENVS id; env \$ENVS wm $WMARGS"
else
	echo "init: starting wm $WMARGS as root"
	env HOME=/root SHELL=/bin/sh XDG_RUNTIME_DIR=/run/user/0 wm $WMARGS &
	WM=\$!
	if [ $sigterm_after -gt 0 ]; then
		sleep $sigterm_after
		echo "init: sending SIGTERM to wm (pid \$WM)"
		kill -TERM \$WM
	fi
	wait \$WM
fi
echo "init: wm exited with status \$?"
sync
poweroff -f
EOF
chmod 0755 "$STAGE/init"

echo "qemu-test: packing initramfs"
(cd "$STAGE" && find . | cpio -o -H newc --quiet | zstd -q -3 -T0 > "$OUT/initramfs.cpio.zst")
ls -lh "$OUT/initramfs.cpio.zst" | awk '{print "qemu-test: initramfs " $5}'

# --- boot -------------------------------------------------------------------
rm -f "$QMP" "$SERIAL"
DISPLAY_ARGS="-display none"
[ "$interactive" = 1 ] && DISPLAY_ARGS="-display gtk"
qemu-system-x86_64 -enable-kvm -cpu host -m 2G -smp 4 \
	-kernel "$KERNEL" -initrd "$OUT/initramfs.cpio.zst" \
	-append "rdinit=/init console=ttyS0 loglevel=4" \
	-device virtio-vga -device virtio-keyboard-pci -device virtio-tablet-pci \
	$DISPLAY_ARGS -qmp "unix:$QMP,server,nowait" \
	-serial "file:$SERIAL" -no-reboot &
QPID=$!
trap 'kill $QPID 2>/dev/null || true' EXIT INT TERM

if [ "$interactive" = 1 ]; then
	wait $QPID
	exit 0
fi

if [ $# -eq 0 ]; then
	set -- \
		"until:60:$SERIAL:wm: listening on" \
		wait:4 \
		"shot:$OUT/01-desktop.png" \
		"type:echo hello\n" \
		wait:1.5 \
		"shot:$OUT/02-typed.png" \
		move:200,150 wait:0.5 move:640,400 wait:0.5 \
		"shot:$OUT/03-pointer.png" \
		click wait:1 \
		"shot:$OUT/04-click.png"
fi
timeout "$timeout_s" python3 "$ROOT/apps/wm/qemu-qmp.py" "$QMP" "$@" || echo "qemu-test: QMP script failed or timed out"

echo "qemu-test: stopping QEMU"
python3 - "$QMP" <<'EOF' || true
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); f = s.makefile("rwb")
f.readline()
for c in ("qmp_capabilities", "quit"):
    f.write(json.dumps({"execute": c}).encode() + b"\n"); f.flush(); f.readline()
EOF
sleep 1
kill $QPID 2>/dev/null || true
wait $QPID 2>/dev/null || true
trap - EXIT INT TERM
echo "qemu-test: serial log: $SERIAL"
grep -E '^(wm|init)' "$SERIAL" | head -40 || true
