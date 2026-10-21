#!/usr/bin/env bash
# The `.Focused` capture path, on real compositors that have no data control.
#
#   focused-test.sh [mutter|gnome-shell|all]     (default: all)
#
# GNOME's compositors offer wl_data_device and nothing else: a client sees the
# selection only while it has keyboard focus, and `wl-paste --watch` refuses to
# run there at all. palmy reports that as `clipboard_watch` = `.Focused`, and
# this window then records the selection each time it is focused. This script
# runs the real application on a private mutter or gnome-shell, nested in a
# private Xvfb (no window on anyone's screen; --headless would do, except that
# its seat has no keyboard, so nothing ever has focus and no selection is ever
# announced), with a private session bus and a private stand-in for the
# system bus so gnome-shell registers nothing with the machine's GDM, and
# drives it with wl-copy and a second window that takes the focus away.
#
# What it asserts, per compositor:
#   1. the window chose the focused offer path, not wl-paste;
#   2. a copy made by another client is recorded once the window has focus
#      back, and read from the offer palmy handed out;
#   3. while another window holds the focus, nothing is recorded; when the
#      focus comes back, the selection *at that moment* is — so of two copies
#      made in the background only the second lands (the documented limit of
#      a compositor that shows the selection to the focused window only);
#   4. a selection flagged by a password manager (x-kde-passwordManagerHint)
#      is refused without a byte of it being read;
#   5. no wl-paste was ever started by the window.
#
# Needs: mutter and/or gnome-shell, Xvfb, dbus-launch, wl-copy. Builds the binary
# into a private directory from the checkout this script lives in.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
WHICH="${1:-all}"
ODIN="${ODIN:-$(command -v odin || echo "$HOME/.local/share/mise/installs/odin/dev-2026-09/odin")}"

WORK="$(mktemp -d /tmp/palmy-clip-focused-XXXXXX)"
BIN="$WORK/clipboard"
"$ODIN" build "$HERE" -collection:palmy="$ROOT/palmy" -collection:shadcn="$ROOT/shadcn" \
  -collection:kit="$ROOT/apps/kit" -out:"$BIN" >"$WORK/build.log" 2>&1 || {
  cat "$WORK/build.log"; exit 1
}

checks=0; fails=0
check() { # check <ok 0|1> <what>
  checks=$((checks + 1))
  if [ "$1" = 1 ]; then echo "  ok    $2"; else fails=$((fails + 1)); echo "  FAIL  $2"; fi
}
is() { [ "$@" ] && echo 1 || echo 0; }
not() { [ "$1" = 1 ] && echo 0 || echo 1; }

PIDS=()
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 0.3
  for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
  [ -n "${DBUS_SESSION_BUS_PID:-}" ] && kill "$DBUS_SESSION_BUS_PID" 2>/dev/null
  PIDS=(); unset DBUS_SESSION_BUS_PID
}
trap 'cleanup; rm -rf "$WORK"' EXIT

history_has() { # history_has <dir> <text> -> 1/0
  PALMY_CLIPBOARD_DIR="$1" WAYLAND_DISPLAY= "$BIN" list --json 2>/dev/null | grep -qF "\"preview\": \"$2\"" && echo 1 || echo 0
}
reads() { # the offer-read counter from the last trace line, or 0
  grep -os 'reads so far [0-9]*' "$1" | tail -1 | grep -o '[0-9]*$' || echo 0
}
offers() { grep -cs '^\[clipboard\] offer ' "$1"; }
wait_for() { # wait_for <seconds> <command...>: until it prints 1
  local end=$((SECONDS + $1)); shift
  while [ $SECONDS -lt $end ]; do [ "$("$@")" = 1 ] && return 0; sleep 0.2; done; return 1
}

run_on() {
  local comp=$1
  echo
  echo "== $comp (nested in a private Xvfb, no data control)"
  command -v "$comp" >/dev/null || { echo "  skipped: $comp is not installed"; return; }
  local run="$WORK/$comp"; mkdir -p "$run/cfg" "$run/data" "$run/cache"; chmod 700 "$run"
  (
    checks=0; fails=0
    export XDG_RUNTIME_DIR="$run" XDG_CONFIG_HOME="$run/cfg" XDG_DATA_HOME="$run/data" XDG_CACHE_HOME="$run/cache"
    export HOME="$run"
    unset WAYLAND_DISPLAY DISPLAY
    eval "$(dbus-launch --sh-syntax)"; export DBUS_SESSION_BUS_ADDRESS
    local sock=wl-focused
    # A free X display number, taken under a lock so two runs never share one.
    exec 8>/tmp/palmy-clip-focused.xlock; flock 8
    local n=70
    while [ -e /tmp/.X11-unix/X$n ] || [ -e /tmp/.X$n-lock ]; do n=$((n + 1)); done
    Xvfb :$n -screen 0 1100x820x24 -nolisten tcp >"$run/xvfb.log" 2>&1 & PIDS+=($!)
    for _ in $(seq 1 50); do [ -e /tmp/.X11-unix/X$n ] && break; sleep 0.1; done
    flock -u 8; exec 8>&-
    if [ "$comp" = gnome-shell ]; then
      dbus-daemon --session --nofork --address="unix:path=$run/sysbus" & PIDS+=($!)
      for _ in $(seq 1 30); do [ -S "$run/sysbus" ] && break; sleep 0.1; done
      DBUS_SYSTEM_BUS_ADDRESS="unix:path=$run/sysbus" MUTTER_DEBUG_DUMMY_MODE_SPECS=1024x768 DISPLAY=:$n \
        gnome-shell --nested --wayland --no-x11 --wayland-display=$sock --unsafe-mode >"$run/comp.log" 2>&1 & PIDS+=($!)
    else
      MUTTER_DEBUG_DUMMY_MODE_SPECS=1024x768 DISPLAY=:$n \
        mutter --nested --wayland --no-x11 --wayland-display=$sock >"$run/comp.log" 2>&1 & PIDS+=($!)
    fi
    for _ in $(seq 1 150); do [ -S "$run/$sock" ] && break; sleep 0.1; done
    [ -S "$run/$sock" ] || { echo "  FAIL  $comp did not start"; tail -5 "$run/comp.log"; exit 1; }
    export WAYLAND_DISPLAY=$sock
    sleep 1
    if [ "$comp" = gnome-shell ]; then
      # gnome-shell starts in the overview, where the keyboard focus belongs
      # to its search entry and no window would ever be told the selection.
      sleep 2
      gdbus call --session --dest org.gnome.Shell --object-path /org/gnome/Shell \
        --method org.gnome.Shell.Eval "Main.overview.hide()" >/dev/null 2>&1
      sleep 1
    fi

    local hist="$run/hist" log="$run/app.log"
    mkdir -p "$hist"
    PALMY_CLIPBOARD_DIR="$hist" PALMY_CLIPBOARD_TRACE=1 "$BIN" >"$log" 2>&1 & local app=$!; PIDS+=($app)
    wait_for 20 sh -c "grep -qs 'capture:' '$log' && echo 1"; sleep 1.5

    check "$(is "$(grep -o 'capture: .*' "$log")" = "capture: Offers_Focused")" \
      "1. the window records through focused offers ($(grep -o 'capture: .*' "$log"))"

    # 2. Another client copies. wl-copy without data control takes the focus
    # for a moment to set the selection, and the focus comes back.
    timeout 10 wl-copy "focused-alpha"
    wait_for 20 history_has "$hist" "focused-alpha"
    check "$(history_has "$hist" "focused-alpha")" "2. a copy by another client is recorded when the focus returns"
    local r2; r2=$(reads "$log")
    check "$(is "$r2" -ge 1)" "   ...read from the offer palmy handed out (reads: $r2)"

    # 3. Another window takes the focus; two copies are made behind it.
    local cover_dir="$run/cover"; mkdir -p "$cover_dir"
    PALMY_CLIPBOARD_DIR="$cover_dir" "$BIN" >"$run/cover.log" 2>&1 & local cover=$!; PIDS+=($cover)
    sleep 2.5
    local o3; o3=$(offers "$log")
    timeout 10 wl-copy "focused-beta"; sleep 1
    timeout 10 wl-copy "focused-gamma"; sleep 1.5
    check "$(is "$(offers "$log")" = "$o3")" "3. no offer reaches the window while another one has the focus"
    check "$(not "$(history_has "$hist" "focused-gamma")")" "   ...so nothing new is recorded yet"
    kill "$cover"; wait "$cover" 2>/dev/null
    wait_for 20 history_has "$hist" "focused-gamma"
    check "$(history_has "$hist" "focused-gamma")" "   when the focus comes back, the selection at that moment is recorded"
    check "$(not "$(history_has "$hist" "focused-beta")")" \
      "   and the copy before it is not: the documented limit without data control"

    # 4. A password manager's copy, made behind another window, refused unread.
    PALMY_CLIPBOARD_DIR="$cover_dir" "$BIN" >"$run/cover2.log" 2>&1 & cover=$!; PIDS+=($cover)
    sleep 2.5
    local r4; r4=$(reads "$log")
    timeout 10 wl-copy --type x-kde-passwordManagerHint "focused-secret"; sleep 1
    kill "$cover"; wait "$cover" 2>/dev/null
    wait_for 20 sh -c "grep -q 'passwordManagerHint.* -> Secret' '$log' && echo 1"
    check "$(grep -q 'passwordManagerHint.* -> Secret' "$log" && echo 1 || echo 0)" \
      "4. a selection flagged x-kde-passwordManagerHint is refused"
    check "$(is "$(reads "$log")" = "$r4")" "   without a byte of it being read (reads: $r4 -> $(reads "$log"))"
    check "$(not "$(history_has "$hist" "focused-secret")")" "   and it is not in the history"

    # 5. Nothing shelled out to wl-paste.
    check "$(pgrep -P "$app" wl-paste >/dev/null && echo 0 || echo 1)" "5. the window started no wl-paste"

    echo "  ($(offers "$log") offers seen; app log: $log)"
    cleanup
    echo "$checks $fails" >"$run/result"
  )
  read -r c f <"$run/result" 2>/dev/null || { c=1; f=1; }
  checks=$((checks + c)); fails=$((fails + f))
}

case $WHICH in
  all) run_on mutter; run_on gnome-shell ;;
  mutter|gnome-shell) run_on "$WHICH" ;;
  *) echo "usage: focused-test.sh [mutter|gnome-shell|all]"; exit 2 ;;
esac
echo
echo "$checks checks, $fails failed"
[ "$fails" = 0 ]
