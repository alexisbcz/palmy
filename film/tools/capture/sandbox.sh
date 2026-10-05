#!/usr/bin/env bash
# Run a command inside the capture sandbox.
#
#   film/tools/capture/sandbox.sh <command> [args...]
#
# The techniques here are the ones `site/scripts/shots-apps.sh` established
# for the documentation screenshots, for the same reason: several of these
# applications honestly report the machine they are running on, and the
# machine belongs to somebody. This is the recording half of that work, so it
# adds a compositor -- which the screenshot pass never needed -- and one thing
# the screenshot pass could not do.
#
#   unshare -U -r       a user namespace, so the rest is available unprivileged
#   unshare -u          a private UTS namespace; `hostname palmy` is then what
#                       every app reads out of /proc/sys/kernel/hostname
#   unshare -p -f
#     --mount-proc      a private PID namespace, so a process table shows only
#                       what was started in here
#   unshare -m          a private mount namespace, which is the new part
#   HOME, XDG_*         pointed into $SB/user, so anything resolved against a
#                       home directory lands somewhere innocuous
#
# THE BIND MOUNTS, which are the point of the mount namespace.
#
# `apps/wm` spawns a fixed table of five programs on F1..F5, by absolute path:
# four examples out of ./bin and /usr/bin/foot. That table is in the window
# manager's source, which this film does not own and must not edit. So the
# paths are bound to other binaries instead -- the window manager is told
# nothing and lies about nothing, it execs the path it always execs.
#
# Two consequences, both deliberate:
#
#   * /usr/bin/foot is bound to /bin/true, so the one key that would open a
#     terminal cannot. The previous recording of this app pressed it, and the
#     shell prompt inside reads `alex@omarchy`, which is why that clip is
#     unusable after ten seconds and why this script exists.
#   * the window manager's own toast still names the *slot* -- "launched
#     counter" -- while the window that appears is a calculator. That toast
#     lasts three seconds (`wall_now() - s.status_at < 3.0` in its status bar),
#     so the steps file leaves four seconds after the last launch and the shot
#     list takes nothing before that. No frame in the film shows a toast
#     naming a program other than the one on screen. If you change the steps,
#     keep that rule.

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SB="${CAPTURE_SANDBOX:-/tmp/palmy-film-capture}"

# The five programs that take the window manager's five spawn slots, in
# F1..F5 order: counter, gallery, todo, foot, pixels.
SLOT_F1="${SLOT_F1:-$ROOT/apps/calc/calc.bin}"
SLOT_F2="${SLOT_F2:-$ROOT/apps/maps/maps.bin}"
SLOT_F3="${SLOT_F3:-$ROOT/apps/sheets/sheets.bin}"
SLOT_F4="${SLOT_F4:-/bin/true}"
SLOT_F5="${SLOT_F5:-$ROOT/apps/calendar/calendar.bin}"

rm -rf "$SB"
mkdir -p "$SB"/user/{Documents,Pictures,Videos,.cache,.config,.local/share} "$SB"/bin

export CAPTURE_ROOT="$ROOT"
export CAPTURE_SB="$SB"
export CAPTURE_SLOTS="$SLOT_F1|$SLOT_F2|$SLOT_F3|$SLOT_F4|$SLOT_F5"
export CAPTURE_CMD_FILE="$SB/cmd"
printf '%s\0' "$@" > "$SB/cmd"

exec unshare -U -r -u -m -p -f --mount-proc --propagation private \
	bash -c '
set -euo pipefail
hostname palmy

ROOT="$CAPTURE_ROOT"; SB="$CAPTURE_SB"
IFS="|" read -r F1 F2 F3 F4 F5 <<< "$CAPTURE_SLOTS"

export HOME="$SB/user"
export XDG_CACHE_HOME="$SB/user/.cache"
export XDG_CONFIG_HOME="$SB/user/.config"
export XDG_DATA_HOME="$SB/user/.local/share"
export XDG_DOCUMENTS_DIR="$SB/user/Documents"
export XDG_PICTURES_DIR="$SB/user/Pictures"
export XDG_VIDEOS_DIR="$SB/user/Videos"
export PATH="$SB/bin:$PATH"
# XDG_RUNTIME_DIR stays as it is: the compositor needs a real socket
# directory, and it carries a uid, not a name.

bind() { [ -e "$2" ] && mount --bind "$1" "$2"; }
bind "$F1" "$ROOT/bin/counter"
bind "$F2" "$ROOT/bin/gallery"
bind "$F3" "$ROOT/bin/todo"
bind "$F4" /usr/bin/foot
bind "$F5" "$ROOT/bin/pixels"

mapfile -d "" -t cmd < "$CAPTURE_CMD_FILE"
exec "${cmd[@]}"
'
