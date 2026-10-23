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
#   HWTEST_LEVEL=1  — level test: record the FF400's own input while a
#                     tone loops through the speakers, and verify mute /
#                     fader / preamp changes in the measured level
#                     (needs a mic on input HWTEST_LEVEL_CH, default 1)

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

# 6. Optional level test — the only check that proves the DEVICE applied
#    a change: record the FF400's own input while a tone loops through
#    the AN1/2 speakers into a mic. Needs HWTEST_LEVEL=1.
if [ "${HWTEST_LEVEL:-0}" = "1" ]; then
    LCH="${HWTEST_LEVEL_CH:-1}"
    IN_IDX=$((LCH - 1))
    METER=.build/debug/ffmeter
    TONE=/tmp/ff400ctl-hwtest-level-tone.wav
    SIL=/tmp/ff400ctl-hwtest-level-sil.wav
    if [ ! -x "$METER" ]; then
        echo "   skipping level test — $METER not built (make hwtest builds it)"
    else
        echo
        echo "== level check (mic = input $LCH, speakers = AN1/2)"
        if system_profiler SPAudioDataType 2>/dev/null \
            | grep -B6 "Default Output Device: Yes" | grep -qi fireface; then
            echo "   default output is the Fireface — good"
        else
            echo "   WARNING: the Fireface doesn't look like the default output device;"
            echo "   the tone may play somewhere else. Set it in System Settings > Sound"
            echo "   or continue anyway if your routing is different."
        fi
        read -r -p "   plays a 1 kHz tone at -20 dBFS through your speakers for ~40 s;
   make sure the mic on input $LCH can hear the speakers. Continue? [y/N] " GO
        if [ "$GO" != "y" ] && [ "$GO" != "Y" ]; then
            echo "   skipped"
        else
            # Originals, for the restore trap.
            STATE=$("$BIN" state --json)
            jval() { echo "$STATE" | python3 -c "import json,sys; j=json.load(sys.stdin); print($1)"; }
            ORIG_OUT0=$(jval 'j["output"][0]')
            ORIG_OUT1=$(jval 'j["output"][1]')
            ORIG_M0=$(jval '"on" if j["outputMute"][0] else "off"')
            ORIG_M1=$(jval '"on" if j["outputMute"][1] else "off"')
            ORIG_IM=$(jval "\"on\" if j[\"inputMute\"][$IN_IDX] else \"off\"")
            ORIG_GAIN=$(jval 'j.get("ampGains",{}).get("0", 0)')

            python3 - "$TONE" "$SIL" <<'EOF'
import math, struct, sys, wave
w = wave.open(sys.argv[1], 'wb')
w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
f = bytearray()
for i in range(48000 * 45):   # 45 s of 1 kHz at -20 dBFS
    v = int(32767 * 0.1 * math.sin(2 * math.pi * 1000 * i / 48000))
    f += struct.pack('<hh', v, v)
w.writeframes(f); w.close()
s = wave.open(sys.argv[2], 'wb')
s.setnchannels(2); s.setsampwidth(2); s.setframerate(48000)
s.writeframes(bytes(48000 * 8 * 4))   # 8 s of silence — keeps a stream up
s.close()
EOF

            # FEEDBACK SAFETY: the mic must not be monitored through the
            # speakers while it records them — mute its input row first.
            # (Recording is pre-mixer; capture is unaffected.)
            "$BIN" mute "$IN_IDX" on >/dev/null 2>&1

            TONE_PID=""; SIL_PID=""; RESTORED=0
            restore() {
                [ "$RESTORED" = "1" ] && return; RESTORED=1
                kill "$TONE_PID" 2>/dev/null
                kill "$SIL_PID" 2>/dev/null
                "$BIN" gain 0 "$ORIG_GAIN" >/dev/null 2>&1
                "$BIN" outvol 0 "$ORIG_OUT0" >/dev/null 2>&1
                "$BIN" outvol 1 "$ORIG_OUT1" >/dev/null 2>&1
                "$BIN" outmute 0 "$ORIG_M0" >/dev/null 2>&1
                "$BIN" outmute 1 "$ORIG_M1" >/dev/null 2>&1
                "$BIN" mute "$IN_IDX" "$ORIG_IM" >/dev/null 2>&1
                rm -f "$TONE" "$SIL"
            }
            trap restore EXIT INT TERM

            # "rms peak" of the mic channel over 1.5 s of capture.
            meas() { "$METER" 1.5 "$LCH" | python3 -c \
                'import json,sys; c=json.load(sys.stdin)["channels"][0]; print(c["rms_db"], c["peak_db"])'; }

            # Noise floor — a playback stream must be running before any
            # capture starts (the device has wedged after a capture made
            # with nothing playing).
            afplay "$SIL" & SIL_PID=$!
            sleep 2
            N=$(meas); echo "   noise floor  N  = $N"
            kill "$SIL_PID" 2>/dev/null; SIL_PID=""

            afplay "$TONE" & TONE_PID=$!
            sleep 1.5
            T=$(meas); echo "   tone level   T  = $T"
            T_RMS=$(echo "$T" | awk '{print $1}')
            if ! python3 -c "import sys; sys.exit(0 if $T_RMS - ${N%% *} >= 15 else 1)"; then
                echo "   SKIP: mic doesn't hear the speakers well enough"
                echo "   (T-N < 15 dB — raise mic gain / move the mic)"
            else
                "$BIN" mainmute on 0 >/dev/null 2>&1; sleep 0.5
                M=$(meas); echo "   muted        M  = $M"
                python3 -c "import sys; sys.exit(0 if $T_RMS - ${M%% *} >= 10 else 1)" \
                    && ok "audible output mute" || bad "mute drop < 10 dB (T=$T M=$M)"

                "$BIN" mainmute off 0 >/dev/null 2>&1; sleep 0.5
                T2=$(meas); echo "   unmuted      T2 = $T2"
                python3 -c "import sys; sys.exit(0 if abs(${T2%% *} - $T_RMS) <= 3 else 1)" \
                    && ok "unmute restores level" || bad "unmute level off (T=$T T2=$T2)"

                "$BIN" main -10dB 0 >/dev/null 2>&1; sleep 0.5
                F=$(meas); echo "   fader -10 dB F  = $F"
                python3 -c "import sys; sys.exit(0 if 6 <= ${T2%% *} - ${F%% *} <= 14 else 1)" \
                    && ok "output fader -10 dB lowers level ~10 dB" \
                    || bad "fader step off (T2=$T2 F=$F)"

                "$BIN" outvol 0 "$ORIG_OUT0" >/dev/null 2>&1
                "$BIN" outvol 1 "$ORIG_OUT1" >/dev/null 2>&1; sleep 0.5
                R=$(meas); echo "   restored     R  = $R"
                python3 -c "import sys; sys.exit(0 if abs(${R%% *} - ${T2%% *}) <= 3 else 1)" \
                    && ok "fader restore returns to level" \
                    || bad "restore level off (T2=$T2 R=$R)"

                if [ "$LCH" = "1" ]; then
                    G1=$(python3 -c "print(min(59, max(10, $ORIG_GAIN)))")
                    [ "$G1" != "$ORIG_GAIN" ] && "$BIN" gain 0 "$G1" >/dev/null 2>&1
                    sleep 0.5
                    B=$(meas); echo "   preamp base  B  = $B (gain $G1)"
                    "$BIN" gain 0 $((G1 + 6)) >/dev/null 2>&1; sleep 0.5
                    P=$(meas); echo "   preamp +6 dB P  = $P"
                    if python3 -c "import sys; sys.exit(0 if ${P##* } > -1 else 1)"; then
                        echo "   SKIP preamp step: clipped (peak ${P##* } dBFS)"
                    else
                        python3 -c "import sys; sys.exit(0 if 3 <= ${P%% *} - ${B%% *} <= 9 else 1)" \
                            && ok "preamp +6 dB raises input ~6 dB" \
                            || bad "preamp step off (B=$B P=$P)"
                    fi
                    "$BIN" gain 0 "$ORIG_GAIN" >/dev/null 2>&1
                else
                    echo "   (preamp step applies to input 1 only — skipped for ch $LCH)"
                fi
            fi
            restore
            echo "   summary: N=$N T=$T M=$M T2=$T2 F=$F R=$R B=${B:-n/a} P=${P:-n/a}"
        fi
    fi
fi

echo
echo "NOTE: writes completed = transactions finished with status 0."
echo "      The mixer RAM is write-only via ASFW — contents were NOT read"
echo "      back; that needs working user-client reads in the driver."
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
