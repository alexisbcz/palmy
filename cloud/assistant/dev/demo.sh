#!/usr/bin/env bash
# Record apps/ai/demo.mp4: a fresh stack, the seed, both assistants on, and
# the window driven on a private headless compositor with the real model.
#
#   cloud/assistant/dev/demo.sh [--name assistant] [--port-base 48521]
#
# Needs ollama serving qwen3:0.6b on 127.0.0.1:11434, sway and wf-recorder.
set -uo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo=$(cd "$here/../.." && pwd)
name=assistant base=48521
while [ $# -gt 0 ]; do
	case "$1" in
	--name) name=$2; shift ;;
	--port-base) base=$2; shift ;;
	esac
	shift
done
api=http://127.0.0.1:$base
davport=$((base + 20))
B=$here/bin
work=$(mktemp -d "${TMPDIR:-/tmp}/palm-assistant-demo.XXXXXX")
trap '[ -n "${davd:-}" ] && kill $davd 2>/dev/null; rm -rf "$work"' EXIT

"$repo/cloud/dev/up.sh" --name "$name" --port-base "$base" --reset 2>&1 | grep -E "new migration"
PALM_CLOUD_URL=$api PALM_DAV_PORT=$davport "$B/palm-davd" serve >"$work/davd.log" 2>&1 &
davd=$!
sleep 0.5
"$here/dev/seed.sh" "$work/m" "$B" "$api" "http://127.0.0.1:$davport" >/dev/null

# The window, as Camille's machine.
cat >"$work/run-ai.sh" <<EOF
#!/usr/bin/env bash
export HOME=$work/m/camille XDG_DATA_HOME= PALM_CLOUD_URL=$api PALM_DAV_URL=http://127.0.0.1:$davport
export PALM_TOOLS_DIR=$B/tools PALM_THEME=\${PALM_THEME:-dark} PALM_TODAY=2026-10-19
exec $B/ai "\$@"
EOF
chmod +x "$work/run-ai.sh"
"$work/run-ai.sh" enable --identity camille.roux --json >/dev/null
"$work/run-ai.sh" enable --identity camille --json >/dev/null

"$repo/apps/tools/headless-record.sh" "$work/run-ai.sh" "$repo/apps/ai/demo.mp4" "$repo/apps/ai/demo.txt" 1320 840
echo "recorded apps/ai/demo.mp4"
