#!/usr/bin/env bash
# End to end: a real palm-notifyd, its socket, a private session bus, and --
# when they are installed -- libnotify's notify-send, a headless compositor
# for the toasts and the center, and Chromium for a web notification.
#
#   apps/notify/e2e.sh [path/to/notify.bin] [--shots DIR] [--no-ui] [--no-browser]
#
# Nothing here touches the user's session: the bus, the runtime directory,
# the state, the config and the compositor are all private to the run, and
# the user's own notification server keeps the user's own bus.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
BIN=""
SHOTS=""
UI=1
BROWSER=1
while [ $# -gt 0 ]; do
	case "$1" in
	--shots) SHOTS="$2"; shift 2 ;;
	--no-ui) UI=0; shift ;;
	--no-browser) BROWSER=0; shift ;;
	*) BIN="$1"; shift ;;
	esac
done
if [ -z "$BIN" ]; then
	BIN="$HERE/notify.bin"
	(cd "$ROOT" && odin build apps/notify -collection:palmy=palmy -collection:kit=apps/kit \
		-collection:shadcn=shadcn -out:"$BIN") || exit 1
fi

# A short runtime directory: unix socket paths stop at 108 bytes.
R="$(mktemp -d /tmp/pn-XXXXXX)"
export XDG_RUNTIME_DIR="$R"
export PALM_NOTIFY_STATE="$R/state" PALM_NOTIFY_CONFIG="$R/config" XDG_CONFIG_HOME="$R/config"
export PALM_NOTIFY_SOUND=off
unset PALM_IDENTITY PALM_NOTIFY_SOCKET WAYLAND_DISPLAY DISPLAY
mkdir -p "$R/config/palmframe"
cat > "$R/config/palmframe/identities.json" <<'JSON'
[{"handle": "camille", "name": "Personal", "color": "teal"},
 {"handle": "camille.roux", "name": "Northwind", "color": "blue"},
 {"handle": "hello", "name": "Public", "color": "amber"}]
JSON

PIDS=()
cleanup() {
	for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
	sleep 0.3
	for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
	rm -rf "$R"
}
trap cleanup EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; return 0; }
expect() { # expect "<what>" <command...>: passes when the command succeeds
	local what="$1"; shift
	if out="$("$@" 2>&1)"; then ok "$what"; else bad "$what" "$out"; fi
}
jq_() { python3 -I -c "
import json,sys
d=json.load(sys.stdin); v=eval(sys.argv[1], {'d': d})
print(json.dumps(v) if isinstance(v, (list, dict)) else v)" "$1"; }

N() { "$BIN" "$@"; }

# ---------------------------------------------------------------------------
echo "== the session bus"
if command -v dbus-daemon >/dev/null; then
	dbus-daemon --session --address="unix:path=$R/bus" --nofork --nopidfile --print-address=3 3>"$R/bus.addr" 2>"$R/bus.log" &
	PIDS+=($!)
	for _ in $(seq 1 50); do [ -S "$R/bus" ] && break; sleep 0.05; done
	export DBUS_SESSION_BUS_ADDRESS="unix:path=$R/bus"
	ok "private dbus-daemon on $R/bus"
else
	echo "  (no dbus-daemon: the freedesktop door is not tested)"
fi

echo "== the daemon (test clock at 17:50)"
NOUI=""
[ "$UI" = 0 ] && NOUI="--no-ui"
N daemon --clock 17:50 $NOUI >"$R/daemon.log" 2>&1 &
DPID=$!
PIDS+=($DPID)
for _ in $(seq 1 50); do [ -S "$R/palm/notify.sock" ] && break; sleep 0.05; done
sleep 0.3
expect "status answers" N status --json
st="$(N status --json)"
[ "$(echo "$st" | jq_ 'd["now"]')" = "17:50" ] && ok "the test clock reads 17:50" || bad "test clock" "$st"
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	b="$(echo "$st" | jq_ 'd["bus"]')"
	[ "$b" = "org.freedesktop.Notifications" ] && ok "owns org.freedesktop.Notifications" || bad "bus name" "$b"
fi

echo "== policies as sentences"
expect "quiet set Northwind \"after 18:00\"" N quiet set --identity camille.roux "after 18:00"
expect "quiet add \"daily digest at 17:00. calls break through\"" N quiet add --identity camille.roux "daily digest at 17:00. calls break through"
expect "Personal: people only" N quiet set --identity camille "people only"
s="$(N quiet get --identity camille.roux --json | jq_ 'd["policy"]["sentence"]')"
[ "$s" = "Quiet after 18:00. Daily digest at 17:00. Calls break through" ] && ok "read back: $s" || bad "sentence" "$s"
out="$(N quiet set --identity camille.roux "after lunch" --json)"; code=$?
[ $code = 2 ] && echo "$out" | grep -q '"clause"' && ok "an unreadable sentence is refused (exit 2) and the clause quoted" || bad "refusal" "$out"
sleep 0.8
grep -q "Quiet after 18:00" "$R/config/policies.json" && ok "stored as structured data with the sentence beside it" || bad "policies.json"

echo "== scope: narrowed, never widened"
out="$(PALM_IDENTITY=camille N send --identity camille.roux "x" --json)"; code=$?
[ $code = 5 ] && ok "inside Personal, sending as Northwind exits 5" || bad "scope (kit)" "$out"
out="$(printf '{"op":"send","note":{"identity":"camille.roux","title":"x"}}\n' | PALM_IDENTITY=camille python3 -I -c '
import socket,sys,os
s=socket.socket(socket.AF_UNIX); s.connect(os.environ["XDG_RUNTIME_DIR"]+"/palm/notify.sock")
s.sendall(sys.stdin.buffer.read()); print(s.recv(65536).decode())')"
echo "$out" | grep -q '"code":5' && ok "the daemon refuses it too, from the sender's own environment" || bad "scope (daemon)" "$out"
r="$(PALM_IDENTITY=camille N send "Scoped" "no --identity" --json | jq_ 'd["identity"]')"
[ "$r" = "camille" ] && ok "an app's identity comes from its PALM_IDENTITY" || bad "identity from env" "$r"
n="$(PALM_IDENTITY=camille N list --json | jq_ 'len([x for x in d["notifications"] if x["identity"]!="camille"])')"
[ "$n" = 0 ] && ok "a scoped list sees only its identity" || bad "scoped list" "$n"

echo "== classes and delivery at 17:50"
d="$(N send --identity camille.roux --class person --app mail --key 'mail:<q4@nw>' "Priya Shah" "Q4 roadmap: can you sign off?" --json)"
[ "$(echo "$d" | jq_ 'd["delivery"]')" = toast ] && ok "a person interrupts" || bad "person" "$d"
d="$(N send --identity camille.roux --class machine --app forge "CI passed" "main @ 4f2a" --json)"
[ "$(echo "$d" | jq_ 'd["delivery"]')" = digest ] && ok "a machine goes to the 17:00 digest (it is 17:50: tomorrow's)" || bad "machine" "$d"
d="$(N send --identity camille --class time --app calendar "Pottery in 15 min" --json)"
[ "$(echo "$d" | jq_ 'd["delivery"]')" = center ] && ok "Personal is people only: a reminder waits in the center" || bad "people only" "$d"

echo "== delivered once"
d="$(N send --identity camille.roux --class person --app home --key 'mail:<q4@nw>' "Priya Shah" "Q4 roadmap: can you sign off by Friday?" --json)"
[ "$(echo "$d" | jq_ 'd["delivery"]')" = updated ] && ok "the same key from another app (home) is an update, not a second toast" || bad "dedupe" "$d"
n="$(N list --json | jq_ 'len([x for x in d["notifications"] if x["key"]=="mail:<q4@nw>"])')"
[ "$n" = 1 ] && ok "one notification for that key" || bad "dedupe count" "$n"
expect "withdraw it" N withdraw 'mail:<q4@nw>'
d="$(N send --identity camille.roux --class person --app mail --key 'mail:<q4@nw>' "Priya Shah" "again" --json)"
[ "$(echo "$d" | jq_ 'd.get("dropped")')" = True ] && ok "a withdrawn key is not delivered again" || bad "tombstone" "$d"

echo "== quiet hours: held, then a digest"
N clock 18:05 >/dev/null
d="$(N send --identity camille.roux --class person --app chat "Ines Roux" "are you there?" --json)"
[ "$(echo "$d" | jq_ 'd["delivery"]')" = digest ] && ok "18:05, Northwind quiet: a person is held" || bad "quiet hold" "$d"
d="$(N send --identity camille.roux --class person --app mail "Theo" "minutes attached" --json)"
d="$(N send --identity camille.roux --class person --urgency critical --category call.incoming --app call "Ines Roux" "Incoming call" --action "answer=Answer|decline=Decline" --json)"
[ "$(echo "$d" | jq_ 'd["delivery"]')" = toast ] && ok "a call breaks through, because the policy says calls break through" || bad "call allowed" "$d"
N quiet set --identity camille.roux "after 18:00" >/dev/null
d="$(N send --identity camille.roux --class person --urgency critical --category call.incoming --app call "Ines Roux" "Incoming call again" --json)"
[ "$(echo "$d" | jq_ 'd["delivery"]')" = digest ] && ok "without that clause, the call is held" || bad "call refused" "$d"
N quiet add --identity camille.roux "daily digest at 17:00. calls break through" >/dev/null
h="$(N list --held --json | jq_ 'd["count"]')"
[ "$h" = 4 ] && ok "four held for Northwind: three while quiet, one machine for the daily digest" || bad "held count" "$h"
N clock 08:01 >/dev/null
sleep 1.3
dg="$(N list --json | jq_ '[x for x in d["notifications"] if x.get("is_digest")][0]')"
echo "$dg" | grep -q "3 notifications while quiet" && ok "08:01: quiet ends, one digest of three goes out" || bad "digest" "$dg"
h="$(N list --held --json | jq_ 'd["count"]')"
[ "$h" = 1 ] && ok "the machine still waits for 17:00" || bad "daily waits" "$h"
N clock 17:00 >/dev/null
sleep 1.3
dg="$(N list --json | jq_ '[x["title"] for x in d["notifications"] if x.get("is_digest")]')"
echo "$dg" | grep -q "in the 17:00 digest" && ok "17:00: the daily digest takes the machine" || bad "daily digest" "$dg"

echo "== do not disturb"
expect "dnd on" N dnd on
d="$(N send --identity camille --class person --app chat "Priya" "dinner?" --json)"
[ "$(echo "$d" | jq_ 'd["delivery"]')" = digest ] && ok "a person is held through do not disturb" || bad "dnd hold" "$d"
d="$(N send --identity camille.roux --class person --urgency critical --category call.incoming --app call "Ines" "call" --json)"
[ "$(echo "$d" | jq_ 'd["delivery"]')" = toast ] && ok "a Northwind call breaks through DND (its policy allows calls)" || bad "dnd call" "$d"
d="$(N send --identity camille --class person --urgency critical --category call.incoming --app call "Mum" "call" --json)"
[ "$(echo "$d" | jq_ 'd["delivery"]')" = digest ] && ok "a Personal call does not (its policy does not)" || bad "dnd call refused" "$d"
expect "dnd off" N dnd off
sleep 1.3
dg="$(N list --identity camille --json | jq_ '[x["title"] for x in d["notifications"] if x.get("is_digest")]')"
echo "$dg" | grep -q "while quiet" && ok "DND off: what it held goes out as a digest" || bad "dnd digest" "$dg"

echo "== a palmy app through apps/kit/notify.odin (apps/notify/demo)"
DEMO="$R/notify-demo"
if (cd "$ROOT" && odin build apps/notify/demo -collection:palmy=palmy -collection:kit=apps/kit \
	-collection:shadcn=shadcn -out:"$DEMO") >"$R/demo-build.log" 2>&1; then
	out="$(PALM_IDENTITY=camille.roux "$DEMO" mail)"
	echo "$out" | grep -q "ok=true" && echo "$out" | grep -q "delivery=toast" && ok "kit.notify from inside Northwind: $out" || bad "demo mail" "$out"
	k="$(N list --json | jq_ "[x['identity'] for x in d['notifications'] if x['key']=='mail:<q4-roadmap@northwind.coop>']")"
	[ "$k" = '["camille.roux"]' ] && ok "its identity came from the process, not from the code" || bad "demo identity" "$k"
	PALM_IDENTITY=camille.roux "$DEMO" call >"$R/demo-call.txt" 2>&1 &
	DP=$!
	PIDS+=($DP)
	for _ in $(seq 1 30); do grep -q "delivery=" "$R/demo-call.txt" && break; sleep 0.1; done
	cid="$(N list --json | jq_ "[x['id'] for x in d['notifications'] if x['key']=='call:7f3a'][0]")"
	N invoke "$cid" answer >/dev/null
	for _ in $(seq 1 30); do kill -0 $DP 2>/dev/null || break; sleep 0.1; done
	grep -q "call: answer pressed" "$R/demo-call.txt" && ok "Answer reached the app listening for it (notify_listen)" || bad "demo call" "$(cat "$R/demo-call.txt")"
	out="$("$DEMO" withdraw)"
	[ "$out" = "withdraw: true" ] && ok "notify_withdraw" || bad "demo withdraw" "$out"
else
	bad "the demo did not build" "$(tail -3 "$R/demo-build.log")"
fi

echo "== the freedesktop door"
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v gdbus >/dev/null; then
	info="$(gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.GetServerInformation 2>&1)"
	echo "$info" | grep -q "Palmframe" && ok "GetServerInformation: $info" || bad "server info" "$info"
	caps="$(gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.GetCapabilities 2>&1)"
	echo "$caps" | grep -q "actions" && ok "GetCapabilities: $caps" || bad "caps" "$caps"
fi
if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] && command -v notify-send >/dev/null; then
	id="$(PALM_IDENTITY=camille.roux notify-send -p -a Thunderbird -c email.arrived "Ines Roux" "Moved the review to Thursday" 2>&1)"
	sleep 0.2
	row="$(N list --json | jq_ "[x for x in d['notifications'] if x['id']==$id][0]")"
	echo "$row" | grep -q '"source": "fdo"' && echo "$row" | grep -q '"identity": "camille.roux"' && ok "notify-send arrives (id $id), identity from the sender's PALM_IDENTITY" || bad "notify-send" "$row"
	id2="$(notify-send -p -r "$id" -a Thunderbird "Ines Roux" "Moved the review to Thursday, 10:00" 2>&1)"
	[ "$id2" = "$id" ] && ok "replaces_id keeps the id ($id2)" || bad "replace" "$id2"
	low="$(notify-send -p -u low -a Backup "Backup done" 2>&1)"; sleep 0.2
	cls="$(N list --json | jq_ "[x['class']+'/'+x['delivery'] for x in d['notifications'] if x['id']==$low][0]")"
	[ "$cls" = "machine/center" ] && ok "low urgency from a third party is a machine: center, silent" || bad "low" "$cls"
	if command -v dbus-monitor >/dev/null; then
		dbus-monitor --session "type='signal',interface='org.freedesktop.Notifications'" >"$R/mon.txt" 2>/dev/null &
		MON=$!
		PIDS+=($MON)
		sleep 0.3
		# notify-send with actions waits for one to be pressed, and prints it.
		notify-send -a Chromium -A open=Open -A settings=Settings "Download complete" "report.pdf" >"$R/action.txt" 2>&1 &
		NS=$!
		PIDS+=($NS)
		sleep 0.5
		aid="$(N list --json | jq_ "max(x['id'] for x in d['notifications'] if x['app']=='Chromium')")"
		N invoke "$aid" settings >/dev/null
		for _ in $(seq 1 20); do kill -0 $NS 2>/dev/null || break; sleep 0.1; done
		grep -q "ActionInvoked" "$R/mon.txt" && grep -q '"settings"' "$R/mon.txt" && ok "invoking an action emits ActionInvoked" || bad "ActionInvoked" "$(tail -5 "$R/mon.txt")"
		[ "$(cat "$R/action.txt")" = settings ] && ok "notify-send, waiting on its actions, heard \"settings\"" || bad "notify-send action" "$(cat "$R/action.txt")"
		cid="$(notify-send -p -a Chromium "To close" 2>&1)"
		gdbus call --session --dest org.freedesktop.Notifications --object-path /org/freedesktop/Notifications --method org.freedesktop.Notifications.CloseNotification "$cid" >/dev/null 2>&1
		sleep 0.3
		# CloseNotification is honoured for the connection that sent it;
		# gdbus is another connection, so this one must still be there.
		left="$(N list --json | jq_ "len([x for x in d['notifications'] if x['id']==$cid])")"
		[ "$left" = 1 ] && ok "CloseNotification from another connection is ignored" || bad "close scope" "$left"
	fi
else
	echo "  (no notify-send or no bus: skipped)"
fi

# ---------------------------------------------------------------------------
if [ "$UI" = 1 ] && command -v sway >/dev/null; then
	echo "== the toasts and the center on a headless compositor"
	cat > "$R/sway.conf" <<CONF
output HEADLESS-1 resolution 1280x800 bg #8a94a6 solid_color
default_border none
exec printf '%s' "\$WAYLAND_DISPLAY" > $R/display
CONF
	env -u WAYLAND_DISPLAY WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 sway -c "$R/sway.conf" >"$R/sway.log" 2>&1 &
	PIDS+=($!)
	for _ in $(seq 1 80); do [ -s "$R/display" ] && break; sleep 0.1; done
	export WAYLAND_DISPLAY="$(cat "$R/display")"
	ok "sway headless on $WAYLAND_DISPLAY"
	N clear all --yes >/dev/null
	N clock 12:00 >/dev/null
	N send --identity camille --app chat --class person "Priya Shah" "Are we still on for dinner on Saturday? I booked the place near the canal." --action "reply=Reply" >/dev/null
	N send --identity camille.roux --app call --class person --urgency critical --category call.incoming "Ines Roux" "Incoming call · Northwind design review" --action "answer=Answer|decline=Decline" >/dev/null
	notify-send -a Chromium "Your download is complete" "quarterly-report-final-v3.pdf · 2.4 MB" 2>/dev/null
	for _ in $(seq 1 50); do N status --json | grep -q '"toasts_running": true' && break; sleep 0.1; done
	sleep 1.2
	if command -v grim >/dev/null; then
		mkdir -p "${SHOTS:-$R/shots}"
		grim "${SHOTS:-$R/shots}/live-toasts.png" && ok "screenshot: live-toasts.png"
	fi
	grep -q "toast surface started" "$R/daemon.log" && ok "the daemon started the toast surface" || bad "toast surface" "$(tail -3 "$R/daemon.log")"
	n="$(N list --showing --json | jq_ 'd["count"]')"
	[ "$n" -ge 3 ] && ok "$n on screen" || bad "showing" "$n"

	if command -v wtype >/dev/null; then
		# The keyboard: `notify focus` is what the wm binding runs.
		f="$(N focus --json | jq_ 'd["focused"]')"
		[ "$f" = toasts ] && ok "notify focus: the toasts take the keyboard" || bad "focus" "$f"
		sleep 1.0
		# One wtype for the whole sequence: each wtype brings its own virtual
		# keyboard and keymap, and a key sent while the client re-binds is
		# lost (apps/tools/headless-record.sh measured one in five).
		wtype -s 500 -k Down -s 1500 -k Delete &
		WT=$!
		sleep 1.3
		grim "${SHOTS:-$R/shots}/live-keyboard.png" 2>/dev/null && ok "screenshot: live-keyboard.png"
		wait $WT
		sleep 0.6
		left="$(N list --json | jq_ "[x['title'] for x in d['notifications'] if x['read'] and not x['showing']]")"
		echo "$left" | grep -q "Priya Shah\|Your download" && ok "Down, Delete: the second toast is dismissed from the keyboard ($left)" || bad "keyboard dismiss" "$left"
		wtype -k Escape
		sleep 0.5
	fi

	# The center, as a panel down the right edge.
	N center >"$R/center.log" 2>&1 &
	CP=$!
	PIDS+=($CP)
	sleep 1.5
	grim "${SHOTS:-$R/shots}/live-center.png" 2>/dev/null && ok "screenshot: live-center.png"
	kill -0 $CP 2>/dev/null && ok "the center is up (layer shell, exclusive keyboard)" || bad "center" "$(cat "$R/center.log")"
	if command -v wtype >/dev/null; then
		# A virtual keyboard's first key can land before the client has
		# bound it; one retry, the same as a person pressing it again.
		for try in 1 2; do
			wtype -s 300 -k Escape
			for _ in $(seq 1 20); do kill -0 $CP 2>/dev/null || break; sleep 0.1; done
			kill -0 $CP 2>/dev/null || break
		done
		if kill -0 $CP 2>/dev/null; then bad "Escape did not close the center"; else ok "Escape closes the center"; fi
	fi
fi

if [ "$UI" = 1 ] && [ "$BROWSER" = 1 ] && command -v chromium >/dev/null && [ -n "${WAYLAND_DISPLAY:-}" ] && [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
	echo "== a web notification from Chromium (Wayland, the private bus)"
	PORT=$((20000 + RANDOM % 20000))
	# Northwind's Chromium profile, where apps/browser keeps it: the
	# identity is read from this path (Chromium rewrites its own environ).
	CH="$R/data/palmframe/browser/camille.roux/cef"
	mkdir -p "$R/web" "$CH/Default"
	cat > "$R/web/index.html" <<'HTML'
<!doctype html><meta charset="utf-8"><title>build</title>
<script>
// The page asks once; the profile below has already said yes for this origin.
Notification.requestPermission().then(p => {
  document.title = "permission " + p;
  const n = new Notification("Build #42 finished", {body: "palmy · main · 6 checks passed", tag: "build-42"});
  n.onclick = () => { fetch("/clicked?tag=build-42"); };
  n.onshow = () => { fetch("/shown"); };
});
</script>
HTML
	python3 -I -m http.server "$PORT" --bind 127.0.0.1 --directory "$R/web" >"$R/http.log" 2>&1 &
	PIDS+=($!)
	printf '{"profile":{"content_settings":{"exceptions":{"notifications":{"http://127.0.0.1:%s,*":{"setting":1}}}}}}' "$PORT" >"$CH/Default/Preferences"
	PALM_IDENTITY=camille.roux chromium --user-data-dir="$CH" --ozone-platform=wayland --no-first-run \
		--no-default-browser-check --password-store=basic --disable-gpu --disable-sync \
		"http://127.0.0.1:$PORT/" >"$R/chrome.log" 2>&1 &
	PIDS+=($!)
	web=""
	for _ in $(seq 1 100); do
		web="$(N list --json | jq_ "[x for x in d['notifications'] if 'Build #42' in x['title']]")"
		[ "$web" != "[]" ] && break
		sleep 0.2
	done
	if [ "$web" != "[]" ]; then
		ok "Chromium's web notification arrived over org.freedesktop.Notifications"
		echo "        $(echo "$web" | jq_ 'd[0]["app"]+" | "+d[0]["title"]+" | "+d[0]["body"].replace(chr(10)," / ")+" | identity="+d[0]["identity"]+" | "+d[0]["class"]+"/"+d[0]["delivery"]')"
		[ "$(echo "$web" | jq_ 'd[0]["identity"]')" = camille.roux ] && ok "it carries Northwind, read from the engine's profile path" || bad "web identity"
		sleep 0.6
		if command -v grim >/dev/null; then grim "${SHOTS:-$R/shots}/live-web.png" && ok "screenshot: live-web.png"; fi
		wid="$(echo "$web" | jq_ 'd[0]["id"]')"
		N invoke "$wid" >/dev/null
		for _ in $(seq 1 30); do grep -q "/clicked" "$R/http.log" && break; sleep 0.2; done
		grep -q "/clicked?tag=build-42" "$R/http.log" && ok "clicking it in Palmframe ran the page's onclick (ActionInvoked default)" || bad "web onclick" "$(tail -3 "$R/http.log")"
	else
		bad "no web notification from Chromium within 20 s" "$(tail -5 "$R/chrome.log")"
	fi
fi

if [ "$fail" != 0 ]; then
	echo "--- daemon log (tail)"
	tail -25 "$R/daemon.log"
fi
echo
echo "e2e: $pass passed, $fail failed"
[ "$fail" = 0 ]
