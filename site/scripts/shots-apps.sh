#!/usr/bin/env bash
#
# Application screenshots for the documentation site.
#
# Every frame here is rendered by palmy itself, offscreen, through each
# application's own `--shot` / `--shots` flag. No compositor is started, so a
# capture can never appear on the user's screen or steal their focus, and
# nothing is recorded from the session.
#
# ---------------------------------------------------------------------------
# What this script is really for
# ---------------------------------------------------------------------------
#
# Running the apps is the easy part. The hard part is that several of them
# honestly report the machine they are running on, and the machine belongs to
# somebody. A screenshot that goes into a git repository must not carry:
#
#   - the account name (`sysmon`'s USER column, `power`'s session list)
#   - the hostname (`sysmon` and `power` both show it)
#   - any path under the real home directory (`screenshot`'s destination,
#     `videoedit`'s project and caption fields, `audio`/`image`/`video`'s
#     title bars, which show the directory of whatever file they opened)
#   - a frame of the webcam or a second of the microphone
#   - any real document, message, password or balance
#
# So each app is run inside a sandbox that makes the true answer unavailable
# rather than asking the app to lie:
#
#   unshare -U -r -u     a private UTS namespace, where `hostname palmy` is
#                        the hostname every app reads out of
#                        /proc/sys/kernel/hostname
#   unshare -p -f
#     --mount-proc       a private PID namespace for `sysmon`, so its process
#                        table contains only the workers started inside it
#   HOME / XDG_*         pointed at $SB/user, so anything resolved relative to
#                        a home directory lands somewhere innocuous
#   $SB/bin on PATH      a fabricated `loginctl`, because the real one lists
#                        the real sessions of the real user
#   $SB/media            synthetic fixtures (ffmpeg lavfi + espeak-ng), which
#                        is the only thing any media app is ever pointed at
#
# The camera at /dev/video0 and the microphone are real. `call` keeps its
# synthetic sources unless `--allow-real-devices` is passed, and it is never
# passed here; `video`, `audio`, `image`, `captions` and `videoedit` are only
# ever given a file. The one call that happens is a loopback call between two
# instances of `call` on 127.0.0.1, both fed a lavfi pattern.
#
#   usage: shots-apps.sh [outdir]      (default: a temp dir, printed at the end)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${1:-$(mktemp -d /tmp/palmy-app-shots-XXXXXX)}"
SB=/tmp/palmy-shots

mkdir -p "$OUT"
command -v ffmpeg >/dev/null || { echo "ffmpeg is required for the synthetic fixtures"; exit 1; }
command -v unshare >/dev/null || { echo "unshare is required for the capture sandbox"; exit 1; }

# ---------------------------------------------------------------------------
# The sandbox
# ---------------------------------------------------------------------------

rm -rf "$SB"
mkdir -p "$SB"/{bin,user,media,proj,ns} "$SB"/user/{Pictures,Videos,Documents}
# The XDG trees have to exist: an app that calls make_directory once on
# $XDG_DATA_HOME/<its own dir> fails when the parent is missing, which is how
# `maps` came back with "no data to render" the first time.
mkdir -p "$SB"/user/.cache "$SB"/user/.config "$SB"/user/.local/share

# whisper.cpp's weights live under the real home, and `captions` finds them by
# searching it. Nothing of the user's is read except the model file itself —
# the audio transcribed is the synthetic espeak-ng clip below — so the model
# directory is linked into the sandbox home rather than copied.
for d in voxtype whisper whisper.cpp; do
  if [ -d "$HOME/.local/share/$d/models" ]; then
    mkdir -p "$SB/user/.local/share/$d"
    ln -sfn "$HOME/.local/share/$d/models" "$SB/user/.local/share/$d/models"
  fi
done

# A fabricated loginctl. `power` lists the machine's real sessions through the
# real one, and a session row is the user's account name in 11px type.
cat > "$SB/bin/loginctl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  list-sessions) printf '%s\n' "3 1000 palmy seat0 tty2" "7 1000 palmy  tty1" ;;
  show-session)
    if [ "$2" = 3 ]; then
      printf 'Name=palmy\nSeat=seat0\nTTY=tty2\nType=wayland\nClass=user\nState=active\nService=sddm-autologin\nTimestamp=Sat 2026-10-04 10:45:36 CEST\nRemote=no\nActive=yes\nIdleHint=no\nLockedHint=no\nCanLock=yes\nLeader=1412\n'
    else
      printf 'Name=palmy\nSeat=\nTTY=tty1\nType=unspecified\nClass=manager\nState=active\nService=systemd-user\nTimestamp=Sat 2026-10-04 10:45:36 CEST\nRemote=no\nActive=yes\nIdleHint=no\nLockedHint=no\nCanLock=no\nLeader=1388\n'
    fi ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$SB/bin/loginctl"

# A fabricated pactl, and a wpctl that refuses.
#
# `mixer` draws the real sound graph, and a device list is a hardware
# fingerprint: the real one on this machine names the monitor over HDMI and
# the USB microphone built into the user's webcam. These fixtures carry only
# the fields mixer actually reads -- index, name, description, state, volume,
# mute, the active port, device.bus / form_factor / class and the bluez codec
# -- so the picture is the real widget drawing a graph that does not exist.
# wpctl is the half of the pair that *writes*; in capture mode it fails, so no
# screenshot can change the volume of a machine somebody is listening to.
mkdir -p "$SB/fixtures"
cat > "$SB/fixtures/sinks.json" <<'JS'
[
 {"index":41,"state":"RUNNING","name":"alsa_output.pci-0000_00_1f.3.analog-stereo","description":"Onboard Audio Controller Analog Stereo","sample_specification":"s32le 2ch 48000Hz","mute":false,
  "volume":{"front-left":{"value":36044,"value_percent":"55%"},"front-right":{"value":36044,"value_percent":"55%"}},
  "active_port":"analog-output-lineout",
  "ports":[{"name":"analog-output-lineout","description":"Line Out"},{"name":"analog-output-headphones","description":"Headphones"}],
  "properties":{"object.id":"41","device.bus":"pci","device.class":"sound"}},
 {"index":44,"state":"SUSPENDED","name":"alsa_output.pci-0000_01_00.1.hdmi-stereo","description":"Display Audio Digital Stereo (HDMI)","sample_specification":"s32le 2ch 48000Hz","mute":false,
  "volume":{"front-left":{"value":26214,"value_percent":"40%"},"front-right":{"value":26214,"value_percent":"40%"}},
  "active_port":"hdmi-output-0",
  "ports":[{"name":"hdmi-output-0","description":"HDMI / DisplayPort"}],
  "properties":{"object.id":"44","device.bus":"pci","device.class":"sound"}},
 {"index":57,"state":"SUSPENDED","name":"bluez_output.02_00_5E_10_22_71.1","description":"Aurora Buds Pro","sample_specification":"s16le 2ch 48000Hz","mute":false,
  "volume":{"front-left":{"value":48497,"value_percent":"74%"},"front-right":{"value":48497,"value_percent":"74%"}},
  "active_port":"headset-output",
  "ports":[{"name":"headset-output","description":"Headset"}],
  "properties":{"object.id":"57","device.bus":"bluetooth","device.form_factor":"headset","api.bluez5.codec":"aptX","device.class":"sound"}}
]
JS
cat > "$SB/fixtures/sources.json" <<'JS'
[
 {"index":42,"state":"SUSPENDED","name":"alsa_input.pci-0000_00_1f.3.analog-stereo","description":"Onboard Audio Controller Analog Stereo","sample_specification":"s32le 2ch 48000Hz","mute":false,
  "volume":{"front-left":{"value":65536,"value_percent":"100%"},"front-right":{"value":65536,"value_percent":"100%"}},
  "active_port":"analog-input-internal-mic",
  "ports":[{"name":"analog-input-internal-mic","description":"Rear Microphone"}],
  "properties":{"object.id":"42","device.bus":"pci","device.class":"sound"}},
 {"index":46,"state":"RUNNING","name":"alsa_input.usb-palmy-studio-mic.mono-fallback","description":"Studio Condenser Mono","sample_specification":"s16le 1ch 48000Hz","mute":false,
  "volume":{"mono":{"value":54394,"value_percent":"83%"}},
  "active_port":"analog-input-mic",
  "ports":[{"name":"analog-input-mic","description":"Microphone"}],
  "properties":{"object.id":"46","device.bus":"usb","device.form_factor":"microphone","device.class":"sound"}},
 {"index":43,"state":"SUSPENDED","name":"alsa_output.pci-0000_00_1f.3.analog-stereo.monitor","description":"Monitor of Onboard Audio Controller","sample_specification":"s32le 2ch 48000Hz","mute":false,
  "volume":{"front-left":{"value":65536,"value_percent":"100%"}},
  "properties":{"object.id":"43","device.class":"monitor"}}
]
JS
cat > "$SB/fixtures/sink-inputs.json" <<'JS'
[
 {"index":312,"corked":false,"mute":false,
  "volume":{"front-left":{"value":45875,"value_percent":"70%"},"front-right":{"value":45875,"value_percent":"70%"}},
  "properties":{"object.id":"312","application.name":"Lumen Player","application.process.binary":"lumen","media.name":"Tidewater Ferry Survey — track 3"}},
 {"index":318,"corked":true,"mute":true,
  "volume":{"front-left":{"value":32768,"value_percent":"50%"},"front-right":{"value":32768,"value_percent":"50%"}},
  "properties":{"object.id":"318","application.name":"Ember Chat","application.process.binary":"ember","media.name":"notification"}}
]
JS
cat > "$SB/fixtures/source-outputs.json" <<'JS'
[
 {"index":327,"corked":false,"mute":false,
  "volume":{"mono":{"value":60293,"value_percent":"92%"}},
  "properties":{"object.id":"327","application.name":"Captions","application.process.binary":"captions","media.name":"speech to text"}}
]
JS
cat > "$SB/bin/pactl" <<'STUB'
#!/usr/bin/env bash
F=/tmp/palmy-shots/fixtures
case "$*" in
  "get-default-sink")     printf 'alsa_output.pci-0000_00_1f.3.analog-stereo\n' ;;
  "get-default-source")   printf 'alsa_input.usb-palmy-studio-mic.mono-fallback\n' ;;
  *"list sinks")          cat $F/sinks.json ;;
  *"list sources")        cat $F/sources.json ;;
  *"list sink-inputs")    cat $F/sink-inputs.json ;;
  *"list source-outputs") cat $F/source-outputs.json ;;
  *) exit 1 ;;
esac
STUB
cat > "$SB/bin/wpctl" <<'STUB'
#!/usr/bin/env bash
echo "wpctl: not available in capture mode" >&2
exit 1
STUB
chmod +x "$SB/bin/pactl" "$SB/bin/wpctl"

# Synthetic media. testsrc2 and sine are what every demo in this repository
# uses; espeak-ng gives `captions` something to actually transcribe.
echo "fixtures…"
ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=size=1280x720:rate=30 \
       -f lavfi -i "sine=frequency=330:sample_rate=48000" -t 12 \
       -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$SB/media/clip.mp4"
ffmpeg -nostdin -v error -y -f lavfi -i "sine=frequency=440:sample_rate=48000" \
       -f lavfi -i "sine=frequency=660" -filter_complex "[0][1]amerge=inputs=2[a]" \
       -map "[a]" -t 20 "$SB/media/tone.wav"
ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=size=1600x1000:rate=1 -frames:v 1 "$SB/media/photo.png"
if command -v espeak-ng >/dev/null; then
  espeak-ng -v en -s 150 -w "$SB/media/speech.wav" \
    "Palmy is a user interface toolkit written in Odin. It talks to Wayland directly, with no libwayland and no graphics card. Every pixel on this screen was drawn by the software rasterizer." >/dev/null 2>&1
  ffmpeg -nostdin -v error -y -f lavfi -i testsrc2=size=1280x720:rate=25 -i "$SB/media/speech.wav" \
         -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$SB/media/talk.mp4"
fi
cp "$ROOT/apps/videoedit/media/sample.srt" "$SB/proj/demo.srt" 2>/dev/null

# ---------------------------------------------------------------------------
# The run, inside a private UTS namespace
# ---------------------------------------------------------------------------

cat > "$SB/ns/run.sh" <<RUN
#!/usr/bin/env bash
hostname palmy
export HOME=$SB/user USER=palmy LOGNAME=palmy
export XDG_PICTURES_DIR=$SB/user/Pictures
export XDG_VIDEOS_DIR=$SB/user/Videos
export XDG_CACHE_HOME=$SB/user/.cache
export XDG_CONFIG_HOME=$SB/user/.config
export XDG_DATA_HOME=$SB/user/.local/share
export PALMY_VIDEOEDIT_PROJECT=$SB/proj/demo.vep
export PALMY_VIDEOEDIT_EXPORT=$SB/proj/export.mp4
export PALMY_VIDEOEDIT_CAPTION=$SB/proj/demo.srt
export PATH=$SB/bin:\$PATH
unset WAYLAND_DISPLAY DISPLAY
cd $ROOT
O=$OUT
M=$SB/media

shot() { echo "  \$1"; timeout 300 "\${@:2}" >/dev/null 2>&1 || echo "    FAILED: \$1"; }

# --- no arguments, no files -------------------------------------------------
shot power       ./apps/power/power.bin           --shot \$O/app-power.png
shot screenshot  ./apps/screenshot/screenshot.bin --shot \$O/app-screenshot.png
shot mixer       ./apps/mixer/mixer.bin           --shot \$O/app-mixer.png
shot maps        ./apps/maps/maps.bin             --shot \$O/app-maps.png
shot sheets      ./apps/sheets/sheets.bin         --shot \$O/app-sheets.png
shot money       ./apps/money/money.bin           --shot \$O/app-money.png
shot photoshop   ./apps/photoshop/photoshop.bin   --shot \$O/app-photoshop.png
shot videoedit   ./apps/videoedit/videoedit.bin   --shot \$O/app-videoedit.png

# --- fed a synthetic file ---------------------------------------------------
shot audio       ./apps/audio/audio.bin \$M/tone.wav  --shot \$O/app-audio.png 2
shot image       ./apps/image/image.bin \$M/photo.png --shot \$O/app-image.png 1
shot video       ./apps/video/video.bin \$M/clip.mp4  --shot \$O/app-video.png 2
[ -f \$M/talk.mp4 ] && shot captions ./apps/captions/captions.bin \$M/talk.mp4 \
     --shot \$O/app-captions.png --pane captions --transcribe

# --- several frames, of which one is the representative one -----------------
mkdir -p \$O/vault \$O/reader
shot vault  ./apps/vault/vault.bin --shot=\$O/vault
shot reader ./apps/reader/reader.bin --shots \$O/reader
cp \$O/vault/03-open.png     \$O/app-vault.png  2>/dev/null
cp \$O/reader/01-epub-light.png \$O/app-reader.png 2>/dev/null

# --- a loopback call between two instances, both on synthetic sources -------
mkdir -p \$O/call
./apps/call/call.bin --bind 47812 --peer 47811 --name Bob --autoanswer --headless \
    --pattern smptebars --video 640x360@30 --quit-after 14 >/dev/null 2>&1 &
sleep 1
timeout 60 ./apps/call/call.bin --bind 47811 --peer 47812 --name Alice --autocall --headless \
    --pattern testsrc2 --video 640x360@30 --shot \$O/call/c --shot-at 6 --quit-after 12 >/dev/null 2>&1
wait
cp \$O/call/c-1.png \$O/app-call.png 2>/dev/null
echo "  call"
RUN
chmod +x "$SB/ns/run.sh"
echo "capturing (private UTS namespace, hostname palmy)…"
unshare -U -r -u -- "$SB/ns/run.sh"

# ---------------------------------------------------------------------------
# sysmon, which needs a private process table as well
# ---------------------------------------------------------------------------
#
# sysmon's whole point is the process list, and the real one is the user's
# session: their shells, their editor, their browser, their account name in
# the USER column and their home directory inside half the command lines.
# A private PID namespace with --mount-proc gives it a /proc containing only
# what this script started, which is a handful of real, harmless workers.
cat > "$SB/ns/sysmon.sh" <<SYS
#!/usr/bin/env bash
hostname palmy
cd $SB/ns
sha256sum /dev/zero &
gzip -9 -c /dev/urandom > /dev/null &
bzip2 -9 -c /dev/zero > /dev/null &
ffmpeg -nostdin -v quiet -f lavfi -i testsrc2=size=1920x1080:rate=60 -t 60 -f null - &
sort -R /dev/urandom > /dev/null 2>&1 &
sleep 1.2
# sysmon lists itself, so its own command line is in the frame. Write to a
# neutral path inside the sandbox and copy the file out afterwards, or the
# output directory's name ends up rendered in the process table.
./sysmon --shot $SB/ns/sysmon.png
kill %1 %2 %3 %4 %5 2>/dev/null
SYS
chmod +x "$SB/ns/sysmon.sh"
cp "$ROOT/apps/sysmon/sysmon.bin" "$SB/ns/sysmon"
echo "  sysmon (private PID namespace)"
timeout 120 unshare -U -r -p -f --mount-proc -u -- "$SB/ns/sysmon.sh" >/dev/null 2>&1
cp "$SB/ns/sysmon.png" "$OUT/app-sysmon.png" 2>/dev/null

# ---------------------------------------------------------------------------
# The applications that render a directory of frames
# ---------------------------------------------------------------------------
#
# These each grew a `--shots <dir>` flag for this gallery, following
# apps/vault/shot.odin: they build their own fixture data, drive the real
# frame procedure through the offscreen renderer and write a numbered set of
# PNGs, the first of which is `app-<name>.png`. Each gets its own directory,
# because two of them write a fixture tree beside the images and the early
# runs of this collided on names like `02-search.png`.
#
# The sandbox still applies: HOME and the XDG directories point into $SB, so
# an app that persists a recents list or a settings file writes there and not
# into the user's.
cat > "$SB/ns/dirs.sh" <<'DIRS'
#!/usr/bin/env bash
hostname palmy
export HOME=/tmp/palmy-shots/user USER=palmy LOGNAME=palmy
export XDG_CACHE_HOME=$HOME/.cache
export XDG_CONFIG_HOME=$HOME/.config
export XDG_DATA_HOME=$HOME/.local/share
export PATH=/tmp/palmy-shots/bin:$PATH
unset WAYLAND_DISPLAY DISPLAY
cd "$1"; OUT="$2"; shift 2
for a in "$@"; do
  d=/tmp/palmy-shots/dirs/$a
  mkdir -p "$d"
  timeout 300 "./apps/$a/$a.bin" --shots "$d" >/dev/null 2>&1
  if [ -f "$d/app-$a.png" ]; then
    cp "$d/app-$a.png" "$OUT/app-$a.png"; echo "  $a"
  else
    echo "  FAILED: $a wrote no app-$a.png"
  fi
done
DIRS
chmod +x "$SB/ns/dirs.sh"
mkdir -p "$SB/dirs"
echo "capturing the --shots directory apps…"
unshare -U -r -u -- "$SB/ns/dirs.sh" "$ROOT" "$OUT" \
  ai archive bluetooth calc calendar chat clipboard colorpick docs editor \
  emoji files greeter launcher mail network notes pickdemo shop slides \
  torrent wm

echo
echo "raw frames in $OUT"
ls "$OUT"/app-*.png 2>/dev/null | wc -l | xargs echo "  app-*.png:"
