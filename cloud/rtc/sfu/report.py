#!/usr/bin/env python3
"""Summarise a demo3.sh run: per-stream latency, jitter, loss and rate, the
dominant-speaker timeline against the talk schedule, and the tier changes."""
import json
import os
import sys

out = sys.argv[1]
epoch = float(open(os.path.join(out, "epoch")).read())
people = []
for name in ("alice", "bob", "carol"):
    p = os.path.join(out, name + ".json")
    if os.path.exists(p):
        people.append(json.load(open(p)))
sfu = json.load(open(os.path.join(out, "sfu.json")))

print()
print("streams (receiver <- sender), capture to receiver on one CLOCK_MONOTONIC_RAW")
print(f"{'receiver':<8} {'sender':<7} {'audio rx':>8} {'wire ms':>8} {'max':>6} {'jitter':>7} {'played ms':>9} "
      f"{'video':>6} {'L0':>5} {'L1':>5} {'video ms':>8} {'lost':>5} {'no key':>6} {'bad':>4}")
for me in people:
    for f in me["from"]:
        print(f"{me['handle']:<8} {f['handle']:<7} {f['audio_rx']:>8} {f['wire_ms']:>8.2f} {f['wire_max_ms']:>6.1f} "
              f"{f['jitter_ms']:>7.2f} {f['played_ms']:>9.2f} {f['video_frames']:>6} {f['l0_frames']:>5} {f['l1_frames']:>5} "
              f"{f['video_ms']:>8.2f} {f['lost']:>5} {f['no_key']:>6} {f['bad_auth']:>4}")

print()
print("senders")
for me in people:
    s = me["sent"]
    print(f"  {me['handle']:<6} L0 {s['l0']} frames ({s['l0_kbps']:.0f} kbit/s), L1 {s['l1']} frames ({s['l1_kbps']:.0f} kbit/s), "
          f"audio {s['audio']} frames; e2ee {me['e2ee']}, {me['generations']} key generations, tier at end {me['tier']}, "
          f"{me['cap_dropped']} packets dropped by its emulated link")

# A safety code covers the roster it was computed for. Someone removed
# mid-call keeps the code of the larger room; the people who stayed rotate
# keys and agree on a new one. So codes are listed with who holds each.
by_code = {}
for me in people:
    by_code.setdefault(me["safety"], []).append(me["handle"])
print()
for code, who in by_code.items():
    print(f"safety code {code}  held by {', '.join(who)}")
if len({me["safety"] for me in people}) == 1:
    print("  -> identical at every participant")
else:
    print("  -> the room changed during the call: each code is shared by the people who were in the room it describes")

print("\ndominant speaker (SFU), against the schedule alice 0-4 s, bob 4-8 s, carol 8-12 s (period 12 s)")
sched = {"alice": 0, "bob": 4, "carol": 8}
for room in sfu["rooms"]:
    for e in room["speakers"]:
        t = e["unix_ms"] / 1000 - epoch
        phase = t % 12
        expect = "alice" if phase < 4 else "bob" if phase < 8 else "carol"
        turn = (t // 12) * 12 + sched.get(e["handle"], 0)
        lag = t - turn
        print(f"  t={t:6.2f}s  {e['handle']:<6} (schedule says {expect}; {lag:+.2f} s after the turn began)")
    for e in room["tiers"]:
        print(f"  tier change at {e['t']:.2f}s after the room opened: {e['handle']} -> {e['tier']} (estimate {e['est']} kbit/s)")
    for prt in room["parts"]:
        print(f"  sfu view: {prt['handle']:<6} in {prt['rx_kbps']:.0f} kbit/s, out {prt['tx_kbps']:.0f} kbit/s, tier {prt['tier']}, "
              f"forwarded L0 {prt['fwd_l0']/1024:.0f} KB, L1 {prt['fwd_l1']/1024:.0f} KB, keyframe requests {prt['kf_requests']}")
print(f"\nsfu: {sfu['rx_pkts']} datagrams in, {sfu['tx_pkts']} out, {sfu['rejected']} rejected, {sfu['bad_token']} bad tokens")
