#!/usr/bin/env bash
# Record apps/drive/demo.mp4 on a private headless compositor, against the
# demo drive cloud/drive/dev/demo.sh builds (it resets the dev database).
#
#   cloud/drive/dev/stack.sh up && cloud/drive/build.sh && apps/drive/record.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
"$ROOT/cloud/drive/dev/demo.sh" /tmp/palm-drive-demo
export PALM_DRIVE_CONFIG=/tmp/palm-drive-demo/conf/drive.conf
export PALM_DRIVE_DIR=/tmp/palm-drive-demo/Drive
export PALM_DRIVE_STATE=/tmp/palm-drive-demo/state
bash "$ROOT/apps/tools/headless-record.sh" "$HERE/drive.bin" "$HERE/demo.mp4" "$HERE/demo.txt" 1240 780
