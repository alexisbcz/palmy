#!/usr/bin/env bash
# What apps/tools/headless-record.sh launches for the attachments/filing demo.
#
# Its real job is the mailbox. This demo moves messages, deletes them and
# saves an attachment, so it must not run against ~/.local/share/palmy-mail:
# it generates its own fixture tree under $DEMO and points the app at that,
# with the Save dialog aimed at a directory in the same tree. Nothing it
# touches belongs to anybody. The tree is left behind afterwards so the saved
# attachment can be compared against the bytes encoded into the message.
#
# It also sends the keystrokes, in one `wtype` invocation, which is a temporary
# measure and not how this should look. headless-record.sh runs one `wtype` per
# step, and on a headless seat only the first of those reaches a palmy window:
# the seat has no permanent keyboard, so its capabilities toggle around every
# invocation, and palmy binds wl_keyboard when the capability appears without
# releasing it when it goes away — the stale id then makes it skip re-binding.
# `foot` on the same compositor receives every invocation, which is what points
# at the toolkit rather than at sway. That is being fixed in palmy; once it has
# landed, delete the `wtype` block below and move these keys into
# attachments-demo.txt as ordinary per-step `key` lines, which is where they
# belong.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

DEMO="${PALMY_MAIL_DEMO_DIR:-/tmp/palmy-mail-demo}"
rm -rf "$DEMO"
mkdir -p "$DEMO/home" "$DEMO/saved"

HOME="$DEMO/home" "$HERE/mail.bin" --fixtures >/dev/null 2>&1

"$HERE/mail.bin" \
  --maildir="$DEMO/home/.local/share/palmy-mail/work" \
  --save-dir="$DEMO/saved" &
APP=$!
trap 'kill $APP 2>/dev/null' TERM INT

# `-s N` waits N ms before the next key.
#
#   j            the second conversation: the one with a binary attachment
#   v            choose an attachment; the inline logo is not in the list
#   w            open the shared Save dialog, name pre-filled and sanitised
#   Return       save the decoded bytes
#   m j j Return move it to Archive — a rename, flag suffix and all
#   z            undo the move
#   d            delete: the same move, with Trash chosen for you
#   h j*6 l      walk the sidebar down to Trash and open it
(
  sleep 3.0
  wtype \
    -s 2600 -k j \
    -s 2500 -k v \
    -s 2200 -k w \
    -s 3000 -k Return \
    -s 3000 -k m \
    -s 2000 -k j \
    -s 700  -k j \
    -s 1500 -k Return \
    -s 2800 -k z \
    -s 2600 -k d \
    -s 2800 -k h \
    -s 1100 -k j \
    -s 700  -k j \
    -s 700  -k j \
    -s 700  -k j \
    -s 700  -k j \
    -s 700  -k j \
    -s 2000 -k l \
    -s 2600 -k k
) >/dev/null 2>&1 &

wait $APP
