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
#   apps/wm/qemu-test.sh --out DIR       build, stage and screenshot in DIR
#   apps/wm/qemu-test.sh --keyboard fr[:variant[:options]]
#                                        write /etc/palm/keyboard in the guest
#   apps/wm/qemu-test.sh --localtime Europe/Paris
#                                        /etc/localtime -> that tzdata zone
#   apps/wm/qemu-test.sh --guest-script F  run shell script F as root in the
#                                        guest once wm listens (e.g. rewrite
#                                        /etc/palm/keyboard, killall -HUP wm)
#   apps/wm/qemu-test.sh --apps "gallery counter"
#                                        also put these ./bin programs (make)
#                                        in the guest, for windows to test with
#   apps/wm/qemu-test.sh --tag wmux-     prefix the QMP socket's name, so two
#                                        agents' VMs never share one
#   apps/wm/qemu-test.sh --hold          after the steps, keep the VM running
#                                        until it is killed, so further QMP
#                                        scripts can drive the same session
#   apps/wm/qemu-test.sh --no-build      reuse the wm binary already in --out
#   apps/wm/qemu-test.sh --vt 1          run wm on /dev/tty1 the way a login
#                                        manager without logind would: the
#                                        node chown'd to palm, XDG_VTNR=1, wm a
#                                        session leader (setsid); tty2 gets a
#                                        line of text so a switch is visible
#   apps/wm/qemu-test.sh --gpu "-device virtio-vga,max_outputs=2"
#                                        the display device(s) instead of
#                                        -device virtio-vga ("-vga std" is
#                                        bochs-drm)
#   apps/wm/qemu-test.sh --linger N      keep the guest up N s after wm exits
#                                        (to look at the console it left)
#   apps/wm/qemu-test.sh --env "K=V ..."  more environment for wm
#   apps/wm/qemu-test.sh --noflip        PALMY_WM_DRM_NOFLIP=1: present with
#                                        SETCRTC + DIRTYFB, never page flip
#   apps/wm/qemu-test.sh --qemu-args "-device qemu-xhci,id=xhci"
#                                        more QEMU arguments (a USB bus to
#                                        hotplug a keyboard onto over QMP)
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
KERNEL="$ROOT/distro/out/bzImage"
BUSYBOX="$ROOT/distro/out/busybox"

as_user=1
kiosk=0
xkb=1
interactive=0
timeout_s=120
wm_args=""
sigterm_after=0
keyboard=""
localtime=""
guest_script=""
apps=""
tag=""
hold=0
build=1
vt=""
gpu="-device virtio-vga"
qemu_args=""
extra_env=""
linger=0
while [ $# -gt 0 ]; do
	case "$1" in
	--out) OUT=$(mkdir -p "$2" && cd "$2" && pwd); shift ;;
	--keyboard) keyboard=$2; shift ;;
	--localtime) localtime=$2; shift ;;
	--guest-script) guest_script=$2; shift ;;
	--apps) apps=$2; shift ;;
	--tag) tag=$2; shift ;;
	--hold) hold=1 ;;
	--no-build) build=0 ;;
	--vt) vt=$2; shift ;;
	--gpu) gpu=$2; shift ;;
	--qemu-args) qemu_args=$2; shift ;;
	--env) extra_env="$extra_env $2"; shift ;;
	--noflip) extra_env="$extra_env PALMY_WM_DRM_NOFLIP=1" ;;
	--linger) linger=$2; shift ;;
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

STAGE="$OUT/root"
QMP="$OUT/${tag}qmp.sock"
SERIAL="$OUT/serial.log"

[ -f "$KERNEL" ] || { echo "qemu-test: no $KERNEL (distro/kernel/build.sh)" >&2; exit 1; }
[ -x "$BUSYBOX" ] || { echo "qemu-test: no $BUSYBOX (distro/busybox/build.sh)" >&2; exit 1; }
mkdir -p "$OUT"

# --- build ------------------------------------------------------------------
cd "$ROOT"
COLL="-collection:palmy=palmy -collection:kit=apps/kit -collection:shadcn=shadcn"
if [ "$build" = 1 ] || [ ! -x "$OUT/wm.bin" ]; then
	echo "qemu-test: building wm, term and launcher"
	odin build apps/wm $COLL -o:speed -out:"$OUT/wm.bin"
fi
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
for app in $apps; do
	[ -x "bin/$app" ] || { echo "qemu-test: no bin/$app (make)" >&2; exit 2; }
	cp "bin/$app" "$STAGE/usr/bin/$app"
done

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

# The system settings the installer writes (distro/INSTALLER.md).
if [ -n "$keyboard" ]; then
	mkdir -p "$STAGE/etc/palm"
	kl=$(echo "$keyboard" | cut -d: -f1)
	kv=$(echo "$keyboard" | cut -s -d: -f2)
	ko=$(echo "$keyboard" | cut -s -d: -f3-)
	printf 'layout = %s\nvariant = %s\noptions = %s\n' "$kl" "$kv" "$ko" > "$STAGE/etc/palm/keyboard"
fi
if [ -n "$localtime" ]; then
	[ -f "/usr/share/zoneinfo/$localtime" ] || { echo "qemu-test: no zone $localtime" >&2; exit 2; }
	mkdir -p "$STAGE/usr/share/zoneinfo/$(dirname "$localtime")"
	cp -L "/usr/share/zoneinfo/$localtime" "$STAGE/usr/share/zoneinfo/$localtime"
	ln -s "../usr/share/zoneinfo/$localtime" "$STAGE/etc/localtime"
fi
GUEST_SCRIPT_RUN=""
if [ -n "$guest_script" ]; then
	cp "$guest_script" "$STAGE/guest-script"
	chmod 0755 "$STAGE/guest-script"
	# Waits for wm's socket, then runs as root in the background, its output
	# on the console (serial.log) prefixed so the QMP steps can wait for it.
	GUEST_SCRIPT_RUN='( while [ ! -S /run/user/1000/wayland-palmy ] && [ ! -S /run/user/0/wayland-palmy ]; do sleep 0.2; done; /guest-script 2>&1 | sed "s/^/guest: /" ) &'
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
# palm-init's hotplug half (distro/init/devices.odin): a device plugged in
# later is given to the input group from its uevent.
cat > /tmp/uevent.sh <<'UEV'
#!/bin/sh
case "\$ACTION:\$DEVNAME" in
add:input/event*) chown root:input /dev/\$DEVNAME; chmod 0660 /dev/\$DEVNAME ;;
esac
UEV
chmod 0755 /tmp/uevent.sh
uevent /tmp/uevent.sh &
ls -l /dev/dri /dev/input
for d in /sys/class/input/event*; do
	echo "input: \$d \$(cat \$d/device/name) ev=\$(cat \$d/device/capabilities/ev) key=\$(cat \$d/device/capabilities/key) abs=\$(cat \$d/device/capabilities/abs) rel=\$(cat \$d/device/capabilities/rel) prop=\$(cat \$d/device/properties)"
done
mkdir -p /run/user/1000 /run/user/0
chown palm:palm /run/user/1000 /home/palm; chmod 0700 /run/user/1000 /run/user/0
$GUEST_SCRIPT_RUN
ENVS="HOME=/home/palm USER=palm SHELL=/bin/sh PATH=/usr/bin XDG_RUNTIME_DIR=/run/user/1000 XDG_SESSION_TYPE=wayland PALMY_WM_DRM_DEBUG=1 $extra_env"
VT="$vt"
if [ -n "\$VT" ]; then
	# What a login manager without logind does for the session's VT: give
	# the user the node (login(1) always has), say which one it is, and
	# start the session as a session leader so the VT can be its terminal.
	chown palm:tty /dev/tty\$VT; chmod 0620 /dev/tty\$VT
	ENVS="\$ENVS XDG_VTNR=\$VT"
	printf '\033[2J\033[H\n  palmy tty2: a text console.\n  Ctrl+Alt+F1 goes back to the desktop.\n' > /dev/tty2
	chvt \$VT
fi
if [ $as_user = 1 ]; then
	echo "init: starting wm $WMARGS as palm (\$(id palm))"
	if [ -n "\$VT" ]; then
		su -s /bin/sh palm -c "env \$ENVS id; env \$ENVS setsid wm $WMARGS </dev/null & wait"
	else
		su -s /bin/sh palm -c "env \$ENVS id; env \$ENVS wm $WMARGS"
	fi
else
	echo "init: starting wm $WMARGS as root"
	env HOME=/root SHELL=/bin/sh XDG_RUNTIME_DIR=/run/user/0 PALMY_WM_DRM_DEBUG=1 $extra_env wm $WMARGS &
	WM=\$!
	if [ $sigterm_after -gt 0 ]; then
		sleep $sigterm_after
		echo "init: sending SIGTERM to wm (pid \$WM)"
		kill -TERM \$WM
	fi
	wait \$WM
fi
echo "init: wm exited with status \$?"
[ $linger -gt 0 ] && sleep $linger
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
	$gpu -device virtio-keyboard-pci -device virtio-tablet-pci $qemu_args \
	$DISPLAY_ARGS -qmp "unix:$QMP,server,nowait" \
	-serial "file:$SERIAL" -no-reboot &
QPID=$!
trap 'kill $QPID 2>/dev/null || true' EXIT INT TERM

if [ "$interactive" = 1 ]; then
	wait $QPID
	exit 0
fi
echo "qemu-test: QEMU pid $QPID, QMP $QMP"

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
if [ "$hold" = 1 ]; then
	echo "qemu-test: holding; drive it with qemu-qmp.py $QMP, kill $QPID to stop"
	wait $QPID || true
	trap - EXIT INT TERM
	exit 0
fi

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
