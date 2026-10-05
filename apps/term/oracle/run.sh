#!/usr/bin/env bash
# Build and run the differential test against libghostty-vt.
#
# This is deliberately a separate program from the terminal. term.bin must not
# link or dlopen libghostty, so the oracle lives in its own package that the
# app never imports, and this script is the only thing that builds it.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
OUT="${TMPDIR:-/tmp}/term-oracle.bin"
odin build "$ROOT/apps/term/oracle" -o:speed -out:"$OUT"
exec "$OUT" "$@"
