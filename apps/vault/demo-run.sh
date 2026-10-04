#!/usr/bin/env bash
# What the recorder launches.
#
# The demo never opens the user's vault. It builds a throwaway one in /tmp
# first, with the sample entries a first run creates: four fake accounts at
# example.com / example.org / 192.0.2.1 (the documentation range), passwords
# generated on the spot by this app's own generator, and the TOTP seed printed
# in RFC 6238. Nothing in a frame of that recording is a real credential, and
# the master password typed on screen is a constant in main.odin.
#
# The timers are shortened so a 50-second take can show them fire: the
# clipboard clears after 12 s instead of 20, and the vault locks itself after
# 16 s idle instead of 300.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

DIR="${PALMY_VAULT_DEMO_DIR:-/tmp/palmy-vault-demo}"
rm -rf "$DIR"
mkdir -p "$DIR"
chmod 700 "$DIR"
VAULT="$DIR/demo.pvz"

"$HERE/vault.bin" --make-demo-vault="$VAULT" >/dev/null || exit 1
exec "$HERE/vault.bin" --vault="$VAULT" --idle=16 --clip=12
