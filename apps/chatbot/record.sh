#!/usr/bin/env bash
# Record the chatbot demo: one chat server, one bot process, one real client,
# on a compositor nobody can see.
#
#   record.sh <out.mp4> <steps.txt> [width] [height]
#
# Three processes, which is the point of the whole design: the bot is an
# ordinary client of the chat server, not a part of it, so a generation that
# takes twenty seconds cannot touch the server's one mutex. The recording is
# of the *client*, which is where streaming has to look right.
#
# Nothing here goes near the user's session. A scratch port and a scratch store
# so the demo cannot read or disturb ~/.local/share/palmy-chat, and the window
# is filmed on a private headless sway via apps/tools/headless-record.sh —
# its own Wayland socket, its own output, its own seat, no lock, nothing on
# anybody's screen.
#
# ollama must already be running. This script will not start it, and will
# never touch `ollama.service`: on this machine ollama is deliberately a user
# process and the unit stays disabled.
set -uo pipefail

OUT="${1:?usage: record.sh <out.mp4> <steps.txt> [w] [h]}"
STEPS="${2:?missing steps file}"
W="${3:-1280}"
H="${4:-800}"

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BOT="$HERE/chatbot.bin"
# The chat client and server live in another agent's directory, so they are
# taken from wherever they were built rather than assumed to be in the tree.
CLI="${CHAT_CLIENT:-$ROOT/apps/chat/chat.bin}"
SRV="${CHAT_SERVER:-$ROOT/apps/chat/server/chat-server.bin}"
MODEL="${MODEL:-qwen3:0.6b}"
NICK="${BOT_NICK:-qwen3-bot}"
PORT="${PORT:-8813}"

for f in "$BOT" "$CLI" "$SRV"; do
  [ -x "$f" ] || { echo "not built: $f"; exit 1; }
done
[ -f "$STEPS" ] || { echo "no steps file: $STEPS"; exit 1; }

curl -s --max-time 2 "http://127.0.0.1:11434/api/version" >/dev/null || {
  echo "ollama is not running. Start it with:  OLLAMA_HOST=127.0.0.1:11434 ollama serve"
  exit 1
}

STORE="$(mktemp -d /tmp/palmy-chatbot-demo-XXXXXX)"
LAUNCH="$STORE/launch-client.sh"
SRV_PID=""; BOT_PID=""

cleanup() {
  [ -n "$BOT_PID" ] && kill "$BOT_PID" 2>/dev/null
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  sleep 0.3
  [ -n "$BOT_PID" ] && kill -9 "$BOT_PID" 2>/dev/null
  [ -n "$SRV_PID" ] && kill -9 "$SRV_PID" 2>/dev/null
  rm -rf "$STORE"
}
trap cleanup EXIT

"$SRV" --port "$PORT" --dir "$STORE" --quiet &
SRV_PID=$!
for _ in $(seq 1 100); do
  (exec 3<>/dev/tcp/127.0.0.1/"$PORT") 2>/dev/null && break
  sleep 0.05
done

# A little real conversation first, so the bot has something to read and the
# window is not empty. `--post` posts one message over the real protocol and
# exits, which is how a nickname speaks without a window.
seed() { "$CLI" --port "$PORT" --nick "$1" --post general "$2" >/dev/null 2>&1; }
seed alexis "Morning — I am splitting the parity harness out into its own binary today."
seed sam    "The shadcn side is measured. The Odin side still is not."
seed alexis "Once both are measured we can put a number on every widget."

"$BOT" --port "$PORT" --nick "$NICK" --model "$MODEL" --channels general &
BOT_PID=$!
sleep 1.0

cat > "$LAUNCH" <<EOF
#!/usr/bin/env bash
exec "$CLI" --port $PORT --nick alexis
EOF
chmod +x "$LAUNCH"

# Why the conversation is posted from here rather than typed into the window.
#
# `headless-record.sh` types with `wtype`, one process per step. Against a
# palmy window only the *first* `wtype` invocation ever lands: three
# invocations 1.5s apart put "A" in the composer and then nothing, on both the
# working tree and the last commit. So a `type` step followed by `key Return`
# silently does nothing, and a demo built out of them records an empty
# conversation. (Reported as a toolkit gap; not something this app can fix.)
#
# alexis therefore speaks over the real protocol with `chat --post`, the same
# frames the composer would have sent, while the recorded window — alexis's own
# client — shows them arrive and shows the bot's answer grow. Nothing about the
# thing being demonstrated is faked: the server, the bot process, the model and
# the streaming edits are all real.
ask() { "$CLI" --port "$PORT" --nick alexis --post general "$1" >/dev/null 2>&1; }

# A stale file from a previous take would make the poller below think the
# recording had already started, and the whole conversation would happen
# before the first frame.
rm -f "$OUT"

(
  # Start the clock when wf-recorder has actually opened the file, so the
  # offsets below are offsets into the recording.
  for _ in $(seq 1 600); do [ -s "$OUT" ] && break; sleep 0.1; done
  sleep 3.0
  ask "@$NICK describe in a few paragraphs how a software rasterizer turns triangles into pixels, and why anyone would write one by hand"
  sleep 16
  ask "@$NICK summarise"
) &
POSTER=$!

echo "recording: server pid $SRV_PID, bot pid $BOT_PID, port $PORT, store $STORE"
bash "$ROOT/apps/tools/headless-record.sh" "$LAUNCH" "$OUT" "$STEPS" "$W" "$H"
rc=$?
kill "$POSTER" 2>/dev/null
echo "done: $OUT"
exit $rc
