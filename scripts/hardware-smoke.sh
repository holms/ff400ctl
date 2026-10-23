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
# Safety: writes back TRACKED cell values — the mix changes only if the
# device's RAM drifted from the tracked state (e.g. a power cycle that
# was never re-applied, in which case the write moves the device toward
# the intended mix). Options:
#   HWTEST_APPLY=1  — additionally run a full `ffctl apply` (~700 writes)
#   HWTEST_AUDIO=1  — interactive: play a tone through the FF400 and ask
#                     you to confirm mute/unmute actually worked
#   HWTEST_PAIR=n   — output pair for the audio test (default 0 = AN1/2)

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

# 3. Burst check: write each input's tracked out0 cell back, 8 cells
#    back-to-back — catches intermittent transaction drops under small
#    bursts without changing the tracked mix.
BURST_LINES=""
for src in 0 1 2 3 4 5 6 7; do
    V=$(echo "$OUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['input'][$src*18])" 2>/dev/null)
    [ -z "$V" ] && V=0
    BURST_LINES+="mix $src 0 $V"$'\n'
done
if printf '%s' "$BURST_LINES" | "$BIN" batch - >/dev/null 2>&1; then
    ok "8 back-to-back writes completed"
else
    bad "write failed during the 8-cell burst"
fi

# 4. Optional full apply — ~700 transactions in a burst; earlier bursts
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

# 5. Optional interactive audio test — the only check that proves the
#    device APPLIED a change: mute the output pair while a tone plays.
if [ "${HWTEST_AUDIO:-0}" = "1" ]; then
    PAIR="${HWTEST_PAIR:-0}"
    echo
    echo "== interactive audio check (pair $PAIR — set HWTEST_PAIR to change)"
    if system_profiler SPAudioDataType 2>/dev/null \
        | grep -B6 "Default Output Device: Yes" | grep -qi fireface; then
        echo "   default output is the Fireface — good"
    else
        echo "   WARNING: the Fireface doesn't look like the default output device;"
        echo "   the tone may play somewhere else. Set it in System Settings > Sound"
        echo "   or continue anyway if your routing is different."
    fi
    TONE=/tmp/ff400ctl-hwtest-tone.wav
    python3 - "$TONE" <<'EOF'
import math, struct, sys, wave
w = wave.open(sys.argv[1], 'wb')
w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100)
frames = bytearray()
for i in range(44100 * 8):   # 8 s of 440 Hz at -12 dBFS
    v = int(32767 * 0.25 * math.sin(2 * math.pi * 440 * i / 44100))
    frames += struct.pack('<hh', v, v)
w.writeframes(frames); w.close()
EOF
    afplay "$TONE" & TONE_PID=$!
    sleep 1
    read -r -p "   tone playing — do you hear it on the FF400 outputs? [y/N] " HEAR
    if [ "$HEAR" = "y" ] || [ "$HEAR" = "Y" ]; then
        "$BIN" mainmute on "$PAIR" >/dev/null 2>&1
        read -r -p "   muted — did the tone go silent? [y/N] " MUTED
        "$BIN" mainmute off "$PAIR" >/dev/null 2>&1
        read -r -p "   unmuted — did the tone come back? [y/N] " BACK
        [ "$MUTED" = "y" ] || [ "$MUTED" = "Y" ] && ok "audible mute confirmed" \
                                               || bad "mute had no audible effect"
        [ "$BACK" = "y" ] || [ "$BACK" = "Y" ] && ok "audible unmute confirmed" \
                                              || bad "unmute had no audible effect"
    else
        echo "   no tone heard — skipped (check output routing / pair)"
    fi
    kill "$TONE_PID" 2>/dev/null; wait "$TONE_PID" 2>/dev/null
    rm -f "$TONE"
fi

echo
echo "NOTE: writes completed = transactions finished with status 0."
echo "      The mixer RAM is write-only via ASFW — contents were NOT read"
echo "      back; that needs working user-client reads in the driver."
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
