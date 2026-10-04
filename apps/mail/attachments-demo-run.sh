#!/usr/bin/env bash
# What apps/tools/headless-record.sh launches for the attachments/filing demo.
#
# It exists for the mailbox. The demo moves messages, deletes them and saves an
# attachment, so it must not run against ~/.local/share/palmy-mail: it
# generates its own fixture tree under $DEMO and points the app at that, with
# the Save dialog aimed at a directory in the same tree. Nothing it touches
# belongs to anybody, and the tree is left behind afterwards so the saved
# attachment can be compared against the bytes encoded into the message:
#
#   /tmp/palmy-mail-demo/saved/measurements.bin
#
# The keystrokes are in attachments-demo.txt, where they belong.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

DEMO="${PALMY_MAIL_DEMO_DIR:-/tmp/palmy-mail-demo}"
rm -rf "$DEMO"
mkdir -p "$DEMO/home" "$DEMO/saved"

HOME="$DEMO/home" "$HERE/mail.bin" --fixtures >/dev/null 2>&1

exec "$HERE/mail.bin" \
  --maildir="$DEMO/home/.local/share/palmy-mail/work" \
  --save-dir="$DEMO/saved"
