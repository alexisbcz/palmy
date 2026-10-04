#!/usr/bin/env bash
# The demo's entry point.
#
# Two things this does that matter, and both are about not touching anything
# real:
#
#   * XDG_DATA_HOME points at a scratch directory, so the recording loads and
#     saves a throwaway book. The user's own ~/.local/share/palmy-money is
#     neither read nor written by a demo, which would otherwise film their
#     actual accounts.
#   * --start-dir points the import dialog at this app's fictitious fixtures
#     rather than at the home directory. It only decides where the dialog
#     opens; nothing is read until a file is chosen in it.
set -u
ROOT=/home/alex/Work/palmy
SCRATCH="$(mktemp -d /tmp/palmy-money-demo-XXXXXX)"
export XDG_DATA_HOME="$SCRATCH"
cd "$ROOT" || exit 1
exec ./apps/money/money.bin --start-dir "$ROOT/apps/money/fixtures" "$@"
