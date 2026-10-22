#!/bin/bash
# hardware-smoke.sh — opt-in end-to-end test against the REAL Fireface 400.
# Never run in CI. Run manually:  make hwtest
#
# What it proves:
#   1. entitlement + IOServiceOpen + user-client handshake work
#      (ffctl connects — this is the path Gatekeeper/SIP can break)
#   2. an async write transaction completes (status 0) — the strongest
#      check available: the FF400's mixer RAM is write-only through
#      ASFW, so we cannot read the cell back to confirm the value.
#
# What it does NOT prove: that the device applied the value (write-only
# RAM + user-client reads currently never complete in ASFW).
#
# Safety: writes back the TRACKED value of in0->out0 — the mix changes
# only if the device's RAM drifted from the tracked state (e.g. a power
# cycle that was never re-applied, in which case the write moves the
# device toward the intended mix). HWTEST_APPLY=1 additionally runs a
# full `ffctl apply` (~700 transactions).

set -u
cd "$(dirname "$0")/.."
BIN="${1:-.build/debug/ffctl}"
[ -x "$BIN" ] || { echo "ffctl not found at $BIN — run: swift build --product ffctl"; exit 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# Is an FF400 present in CoreAudio? (Connecting to the ASFWDriver user
# client succeeds whenever the controller exists — that does NOT prove
# the FF400 is powered on, so check the audio device list instead.)
if ! system_profiler SPAudioDataType 2>/dev/null | grep -qi "fireface 400"; then
    echo "SKIP: no Fireface 400 in CoreAudio device list — plug it in and power it on"
    exit 0
fi
echo "== hardware smoke against $BIN"

# 1. Real connect: entitlement + open + handshake
if OUT=$("$BIN" state --json 2>&1); then
    ok "connected to ASFW user client"
else
    bad "ffctl could not connect: $OUT"
    echo "== $pass passed, $fail failed"; exit 1
fi

# 2. Idempotent write: write the tracked in0->out0 value back.
#    Exit 0 = the async transaction completed (device acked the write).
CUR=$(echo "$OUT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["input"][0])' 2>/dev/null)
if [ -z "$CUR" ]; then
    bad "could not read tracked in0->out0 from state --json"
else
    echo "   tracked in0->out0 = $CUR — writing it back"
    if "$BIN" mix 0 0 "$CUR" >/dev/null 2>&1; then
        ok "write transaction completed (status 0)"
    else
        bad "write transaction failed or timed out"
    fi
fi

# 3. Optional full apply — ~700 transactions in a burst; earlier bursts
#    froze the FF400, so this is opt-in.
if [ "${HWTEST_APPLY:-0}" = "1" ]; then
    if OUT=$("$BIN" apply 2>&1) && ! echo "$OUT" | grep -q "failed: [1-9]"; then
        ok "full apply completed: $OUT"
    else
        bad "full apply reported failures: $OUT"
    fi
else
    echo "   (skipping full apply — set HWTEST_APPLY=1 to include it)"
fi

echo
echo "NOTE: writes completed = transactions finished with status 0."
echo "      The mixer RAM is write-only via ASFW — contents were NOT read"
echo "      back; that needs working user-client reads in the driver."
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
