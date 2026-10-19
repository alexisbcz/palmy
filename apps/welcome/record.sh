#!/usr/bin/env bash
# Record the first run as a fresh person against a local cloud/dev stack.
#
#   cloud/dev/up.sh --name onboarding --port-base 51521 --reset
#   bash apps/welcome/record.sh --port-base 51521 [out.mp4]           # the film
#   bash apps/welcome/record.sh --port-base 51521 --window [out.mp4]  # a take
#
# The film (default) is `welcome drive` typing into the window offscreen,
# letter by letter, against the real server; every tenth of a second is a
# PNG, and ffmpeg makes them a video. It is the same run e2e.sh checks, so
# what it shows is what was verified.
#
# --window runs the real window on a private headless compositor
# (apps/tools/headless-record.sh) driven by demo.txt through wtype. It works,
# but wtype delivers keys and text so that a Tab can land in the same frame
# as the letters before it, and palmy applies the text after the focus has
# moved: the waits in demo.txt are there for that, and a busy machine can
# still lose a step. Use it to see the window under a real compositor; use
# the film for the demo.
#
# The mail server (palm-maild) runs on base+70..72 against the stack.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BASE=54321
WINDOW=0
while [ $# -gt 0 ]; do
	case "$1" in
	--port-base) BASE=$2; shift 2 ;;
	--window) WINDOW=1; shift ;;
	*) break ;;
	esac
done
OUT="${1:-$HERE/demo.mp4}"
STEPS="${2:-$HERE/demo.txt}"

WORK=$(mktemp -d /tmp/welcome-record.XXXXXX)
MAILD=""
COLLAB=""
trap '[ -n "$MAILD" ] && kill "$MAILD" 2>/dev/null; [ -n "$COLLAB" ] && kill "$COLLAB" 2>/dev/null; pkill -f "$WORK/" 2>/dev/null; rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN" "$WORK/home/.run"
chmod 700 "$WORK/home/.run"
COLL=(-collection:palmy="$ROOT/palmy" -collection:kit="$ROOT/apps/kit" -collection:shadcn="$ROOT/shadcn" -collection:drive="$ROOT/cloud/drive")
for a in welcome accounts vault calendar contacts notes chat drive; do
	odin build "$ROOT/apps/$a" "${COLL[@]}" -out:"$BIN/$a" >/dev/null 2>&1 || echo "build $a failed"
done
odin build "$ROOT/cloud/drive/palm-drive" "${COLL[@]}" -out:"$BIN/palm-drive" >/dev/null 2>&1 || echo "build palm-drive failed"
odin build "$ROOT/apps/mailcore" -out:"$BIN/mailcore" >/dev/null 2>&1 || echo "build mailcore failed"
odin build "$ROOT/cloud/mail" -out:"$BIN/palm-maild" >/dev/null 2>&1 || echo "build palm-maild failed"

PALM_JWT_SECRET=super-secret-jwt-token-with-at-least-32-characters-long \
PALM_REST_PORT=$((BASE + 11)) PALM_AUTH_PORT=$((BASE + 10)) \
PALM_SMTP_PORT=$((BASE + 70)) PALM_SUBMIT_PORT=$((BASE + 71)) PALM_JMAP_PORT=$((BASE + 72)) \
"$BIN/palm-maild" serve >"$WORK/maild.log" 2>&1 &
MAILD=$!
# Notes sync, when the tree (or WELCOME_E2E_NOTES_TREE) has it: e2e.sh says how.
NT="${WELCOME_E2E_NOTES_TREE:-$ROOT}"
if [ -d "$NT/cloud/collab/server" ] && grep -q 'verb = "sync"' "$NT/apps/notes/cli.odin" 2>/dev/null; then
	odin build "$NT/apps/notes" -collection:palmy="$NT/palmy" -collection:kit="$NT/apps/kit" -collection:shadcn="$NT/shadcn" -out:"$BIN/notes" >/dev/null 2>&1
	odin build "$NT/cloud/collab/server" -o:speed -out:"$BIN/palm-collab" >/dev/null 2>&1
	PALM_CLOUD_URL="http://127.0.0.1:$BASE" \
	PALM_COLLAB_SERVICE_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU \
	"$BIN/palm-collab" --port $((BASE + 75)) >"$WORK/collab.log" 2>&1 &
	COLLAB=$!
fi

# The welcome as a person with an empty home sees it.
person() {
	env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME -u PALM_IDENTITY -u PALM_CLOUD_SESSION -u PALM_CLOUD_DIR \
		HOME="$WORK/home" PATH="$BIN:/usr/bin:/bin" \
		PALM_CLOUD_URL="http://127.0.0.1:$BASE" PALM_LOCALE_DIR="$ROOT/distro/locale" WELCOME_BIN_DIR="$BIN" \
		PALM_MAIL_JMAP_PORT=$((BASE + 72)) PALM_MAIL_SUBMIT_PORT=$((BASE + 71)) PALM_THEME=dark \
		PALM_COLLAB_URL="ws://127.0.0.1:$((BASE + 75))" "$@"
}

if [ "$WINDOW" = 1 ]; then
	cat >"$WORK/run-welcome" <<EOF
#!/bin/sh
unset XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME PALM_IDENTITY PALM_CLOUD_SESSION PALM_CLOUD_DIR
export HOME="$WORK/home" PATH="$BIN:/usr/bin:/bin"
export PALM_CLOUD_URL="http://127.0.0.1:$BASE" PALM_LOCALE_DIR="$ROOT/distro/locale" WELCOME_BIN_DIR="$BIN"
export PALM_MAIL_JMAP_PORT=$((BASE + 72)) PALM_MAIL_SUBMIT_PORT=$((BASE + 71)) PALM_THEME=dark
export PALM_COLLAB_URL="ws://127.0.0.1:$((BASE + 75))"
exec "$BIN/welcome" run
EOF
	chmod +x "$WORK/run-welcome"
	bash "$ROOT/apps/tools/headless-record.sh" "$WORK/run-welcome" "$OUT" "$STEPS" 1280 800
else
	person env WELCOME_DRIVE_FILM="$WORK/film" WELCOME_DRIVE_NAME="Camille Roux" XDG_RUNTIME_DIR="$WORK/home/.run" \
		welcome drive --email camille@example.org --theme dark --json
	ffmpeg -v error -y -framerate 10 -i "$WORK/film/%06d.png" -c:v libx264 -pix_fmt yuv420p -crf 20 -preset veryfast "$OUT" &&
		echo "wrote $OUT ($(ls "$WORK/film" | wc -l) frames)"
fi
echo "what the run left behind:"
ls "$WORK/home/Drive" "$WORK/home/Documents" 2>&1 | sed 's/^/  /'
sed 's/^/  /' "$WORK/home/.config/palm/sync.conf" 2>/dev/null
