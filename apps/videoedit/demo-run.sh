#!/usr/bin/env bash
# The binary as the headless recorder has to start it.
#
# Two things the take needs that a correct desktop application does not.
#
# 1. A keyboard that exists before the app does.
#
#    `headless-record.sh` starts sway with `WLR_BACKENDS=headless` and
#    `WLR_LIBINPUT_NO_DEVICES=1`, so the seat begins life with
#    `capabilities: 0` and no input devices at all. `wtype` creates a
#    `zwp_virtual_keyboard_v1` for the duration of one invocation, which does
#    make sway advertise a keyboard — measured:
#
#      seats before wtype:  capabilities 0, devices []
#      seats during wtype:  capabilities 2, devices [wlr_virtual_keyboard_v1]
#      seats after  wtype:  capabilities 0, devices []
#
#    palmy binds `wl_keyboard` from the capabilities it sees when it binds the
#    seat and does not re-check when a later `wl_seat.capabilities` adds one.
#    An app started on that empty seat therefore never receives a key, however
#    many times `wtype` runs afterwards — the whole take plays out with the app
#    hearing nothing, which is what a 92-second recording of an untouched
#    editor looked like. Holding one virtual keyboard open for the length of
#    the take means the seat already has keyboard capability when the app binds
#    it, and every `wtype` after that lands. **This is a palmy gap, worked
#    around here rather than patched**; the fix belongs in the toolkit's seat
#    handling.
#
#    `-k Control_L` twice with a very long gap between them is a keyboard held
#    open and nothing else: a bare modifier press and release is not a
#    shortcut, so it cannot disturb what is being filmed.
#
# 2. Something to film.
#
#    wf-recorder writes a frame when the output is damaged, and an editor
#    nobody is touching damages nothing. VE_RECORD asks the frame loop for a
#    repaint every tick. It is off in normal use, where an idle editor goes
#    back to blocking in poll like any other palmy window.
if command -v wtype >/dev/null; then
  wtype -s 900000 -k Control_L -k Control_L &
  HOLD=$!
  # `exec` below keeps this shell's PID, so `$$` becomes the app once it is
  # running and this watchdog releases the keyboard the moment the take ends.
  # Without it a long `wtype` outlives the recording and sits in the process
  # table for a quarter of an hour.
  ( while kill -0 "$$" 2>/dev/null; do sleep 2; done; kill "$HOLD" 2>/dev/null ) &
fi
sleep 0.6
# The binary beside this script, not a fixed checkout: a worktree's take must
# film the worktree's build.
exec env VE_RECORD=1 "$(cd "$(dirname "$0")" && pwd)/videoedit.bin" "$@"
