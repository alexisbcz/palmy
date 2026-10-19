#!/usr/bin/env bash
# Build the mail pieces into bin/: palm-maild, mailcore (and its test server),
# and the apps/mail client.
#
#   cloud/mail/dev/build.sh [OUT_SUFFIX]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
SUF=${1:-}
mkdir -p "$ROOT/bin"
cd "$ROOT"
odin build cloud/mail -out:"bin/palm-maild$SUF"
odin build apps/mailcore -out:"bin/mailcore$SUF"
odin build apps/mailcore/testserver -out:"bin/mailcore-testserver$SUF"
odin build apps/mail \
	-collection:palmy="$ROOT/palmy" -collection:shadcn="$ROOT/shadcn" -collection:kit="$ROOT/apps/kit" \
	-out:"bin/mail$SUF"
echo "built: bin/palm-maild$SUF bin/mailcore$SUF bin/mailcore-testserver$SUF bin/mail$SUF"
