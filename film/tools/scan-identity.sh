#!/usr/bin/env bash
# Scan source footage for the user's identity before any frame of it ships.
#
# A frame that reaches site/public/film/ reaches a public CDN, where a cached
# frame is awkward to retract. This runs over every clip the shot list draws
# from, samples frames across the whole duration, OCRs each one, and greps the
# text for anything that identifies the machine or its owner.
#
#   usage: film/tools/scan-identity.sh [frames-per-clip] [clip[@from-to] ...]
#
# A clip may be given as `path@from-to` in seconds, which scans only that
# window. That is not a loophole, it is how `apps/wm/demo.mp4` is used: a
# terminal with the user's shell prompt in it opens ten seconds in, the shot
# list takes nothing after 7.3 s, and scanning the whole clip would report a
# frame that cannot reach the film.
#
# Exit status is 1 if anything matched, so it can gate a build.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Per-run by default. Two of these overlapping used to share one directory,
# and the first thing each does is `rm -rf` it -- so one run deleted the
# other's frames mid-scan and the survivor reported "ok" for clips it had
# never OCRed. A safety gate that passes because its evidence was deleted is
# worse than no gate.
OUT="${SCAN_OUT:-$ROOT/film/.scan/run-$$}"
N="${1:-8}"; shift || true

CLIPS=("$@")
if [ ${#CLIPS[@]} -eq 0 ]; then
	mapfile -t CLIPS < <(ls "$ROOT"/apps/*/demo.mp4 \
		"$ROOT"/film/.work/capture/*.mp4 2>/dev/null)
fi

# Anything here must never appear in a published frame. The first group is
# the obvious identity; the rest were each found by eye in a clip that the
# first group had already passed, which is the whole argument for looking as
# well as grepping:
#
#   * real wifi SSIDs name a household and, through a geolocation database,
#     an address -- `network` lists every neighbouring network;
#   * Bluetooth MACs and hardware model names name the machine;
#   * `Brio` is the real webcam, whose microphone shows up in the mixer;
#   * the desktop's own crash toasts were captured into several takes;
#   * `ChatGPT Image` and a `Downloads` under a home directory reached a frame
#     through the real home directory, which also carried real photographs of
#     real people. Bare `Downloads` is not enough on its own: several demos
#     write a synthetic one under /tmp.
IDENTITY='alex|bouchez|/home/|gmail|@[a-z0-9-]+\.(com|net|org|fr)|password-store|\.gnupg|\.ssh|omarchy|id_rsa|id_ed25519|BEGIN (RSA|OPENSSH|PGP)'
HARDWARE='Livebox|Freebox|SFR[_-]|Bbox|[0-9A-F]{2}(:[0-9A-F]{2}){4,}|Brio|CMF Headphone'
DESKTOP='Process crashed|Click to diagnose|Claude Code|ChatGPT Image|~/Downloads|home/[a-z]+/Downloads'
PATTERN="$IDENTITY|$HARDWARE|$DESKTOP"

rm -rf "$OUT"; mkdir -p "$OUT/frames" "$OUT/text"
hits=0
for spec in "${CLIPS[@]}"; do
	clip="${spec%%@*}"
	[ -f "$clip" ] || continue
	name="$(basename "$(dirname "$clip")")-$(basename "$clip" .mp4)"
	from=0
	to=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$clip")
	if [ "$spec" != "$clip" ]; then
		window="${spec#*@}"
		from="${window%%-*}"
		to="${window##*-}"
		name="$name@$from-$to"
	fi
	for i in $(seq 0 $((N - 1))); do
		t=$(awk -v a="$from" -v b="$to" -v i="$i" -v n="$N" \
			'BEGIN{printf "%.2f", a + (b-a)*(i+0.5)/n}')
		png="$OUT/frames/$name-$i.png"
		ffmpeg -nostdin -v error -ss "$t" -i "$clip" -frames:v 1 -y "$png" 2>/dev/null
		[ -s "$png" ] || continue
		tesseract "$png" "$OUT/text/$name-$i" --psm 6 2>/dev/null
	done
	found=$(cat "$OUT/text/$name"-*.txt 2>/dev/null | grep -onEi "$PATTERN" | sort -u -t: -k2 | head -8)
	if [ -n "$found" ]; then
		printf 'HIT  %-32s %s\n' "$name" "$(echo "$found" | tr '\n' ' ')"
		hits=$((hits + 1))
	else
		printf 'ok   %-32s\n' "$name"
	fi
done
echo "---"
echo "clips scanned: ${#CLIPS[@]}   clips with hits: $hits"
[ "$hits" -eq 0 ]
