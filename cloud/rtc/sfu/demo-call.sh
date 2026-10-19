# Sourced by cloud/rtc/demo.sh (CALL_DEMO=1): a three-way call in #design,
# admitted by the real gateway, carried by the real SFU.
#
# Unlike demo3.sh, nothing here mints a token with the SFU secret. Each
# participant asks palm-rtc for one with `chat call '#design'`, as its own
# identity; Postgres decides whether that identity may post in #design, and
# only then does the gateway mint a 60-second token for exactly that identity
# and call. Fifteen seconds in, Alice removes Carol from the space: the
# gateway tells the SFU, and Carol is dropped from the call mid-sentence.
#
# Uses as(), jsonof(), $BIN, $OUT, $AW, $BW, $C and $SFU_PORT from demo.sh.

CALL_OUT=$OUT/call-$RUN
mkdir -p "$CALL_OUT"
SECS=${CALL_SECS:-22}

# The SFU, linked to the gateway: it reports who is in the room, and takes
# the gateway's order to drop anyone who loses access mid-call.
"$BIN/palm-sfu" --bind 127.0.0.1 --port "$SFU_PORT" --secret-file "$OUT/sfu.secret" \
	--gateway "127.0.0.1:$RTC_PORT" --stats --json-out "$CALL_OUT/sfu.json" --quit-after $((SECS + 4)) \
	> "$CALL_OUT/sfu.log" 2>&1 &
SFU_PID=$!
sleep 0.5

TA=$(jsonof alice "$AW" chat call '#design')
TB=$(jsonof bob "$BW" chat call '#design')
TC=$(jsonof carol "$C" chat call '#design')
echo "call $(echo "$TA" | jq -r .call) on $(echo "$TA" | jq -r .sfu): three tokens, one per identity"
for t in "$TA" "$TB" "$TC"; do
	[ "$(echo "$t" | jq -r .call)" = "$(echo "$TA" | jq -r .call)" ] || { echo "not the same call"; exit 1; }
done

EPOCH=$(python3 -c 'import time; print(f"{time.time() + 1.5:.3f}")')
echo "$EPOCH" > "$CALL_OUT/epoch"
common=(--sfu "127.0.0.1:$SFU_PORT" --headless --null-audio --quit-after "$SECS" --talk-period 12 --epoch "$EPOCH")
"$BIN/call" "${common[@]}" --join-token "$(echo "$TA" | jq -r .token)" --talk 0-4 --tone 440 --pattern testsrc2 \
	--json-out "$CALL_OUT/alice.json" > "$CALL_OUT/alice.log" 2>&1 &
PA=$!
"$BIN/call" "${common[@]}" --join-token "$(echo "$TB" | jq -r .token)" --talk 4-8 --tone 554 --pattern testsrc \
	--json-out "$CALL_OUT/bob.json" > "$CALL_OUT/bob.log" 2>&1 &
PB=$!
"$BIN/call" "${common[@]}" --join-token "$(echo "$TC" | jq -r .token)" --talk 8-12 --tone 659 --pattern life \
	--json-out "$CALL_OUT/carol.json" > "$CALL_OUT/carol.log" 2>&1 &
PC=$!

sleep 6
echo "six seconds in, #design as Bob's chat sees it:"
as bob "$BW" chat channels --space Northwind
sleep 9
say "mid-call revocation: Alice removes Carol from the space"
as alice "$AW" chat remove Northwind "$C" --yes
wait $PA $PB $PC || true
wait $SFU_PID || true
echo "what the SFU and the gateway said about it:"
grep -h -i "kick\|left\|removed\|gateway" "$CALL_OUT/sfu.log" "$OUT/palm-rtc.log" 2>/dev/null | head -20 || true
python3 "$ROOT/cloud/rtc/sfu/report.py" "$CALL_OUT" || true
