#!/bin/bash
# e2e-cli.sh — end-to-end tests driving the real compiled ffctl binary
# against a fake device (FFCTL_FAKE_HW) and an isolated state dir
# (FFCTL_STATE_DIR). No FireWire hardware needed — runs in CI.
#
# Asserts on: exit codes, stdout, the register-write log, and the
# persisted state.json (via `ffctl state --json` — itself exercised
# through the fake device, parsing JSON with python3).
#
# Usage: scripts/e2e-cli.sh [path-to-ffctl]   (default: .build/debug/ffctl)
#
# NOTE on gain arguments: "+NdB"/"-NdB" are RELATIVE steps whenever the
# command has a tracked current value (parseGainArgument). Absolute dB
# needs a bare "NdB" or hex, e.g. "0x8000". Scenarios below account for
# that (and verify the relative-step behavior explicitly).

set -u
cd "$(dirname "$0")/.."
BIN="${1:-.build/debug/ffctl}"
[ -x "$BIN" ] || { echo "ffctl not found at $BIN — run: swift build --product ffctl"; exit 1; }
command -v python3 >/dev/null || { echo "python3 required for JSON assertions"; exit 1; }

T=$(mktemp -d /tmp/ffctl-e2e.XXXXXX)
trap 'rm -rf "$T"' EXIT
export FFCTL_STATE_DIR="$T/state"
export FFCTL_FAKE_HW="$T/writes.log"

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }

# run <args...> — execute ffctl in the sandboxed env; rc in $RC, output in $OUT
run() { OUT=$("$BIN" "$@" 2>&1); RC=$?; }

expect_rc()   { [ "$RC" -eq "$1" ] && ok || bad "$2 — exit $RC, want $1"; }
expect_out()  { echo "$OUT" | grep -qF "$1" && ok || bad "$2 — stdout missing '$1'"; }
expect_log()  { grep -qF "$1" "$FFCTL_FAKE_HW" && ok || bad "$2 — write log missing '$1'"; }

# expect_last <addr8hex> <val8hex> <name> — assert the LAST write to an
# address, not just that some write contained the value
expect_last() {
    local got
    got=$(grep -i "^$1 " "$FFCTL_FAKE_HW" | tail -1 | awk '{print tolower($2)}')
    [ "$got" = "$2" ] && ok || bad "$3 — last write to $1 = '$got', want $2"
}

# jget <key> [index] — pull a value out of `state --json`
jget() {
    "$BIN" state --json | python3 -c "
import json,sys
v=json.load(sys.stdin)['$1']
print(v if '$2' == '' else v[int('$2')])" 2>/dev/null
}
expect_state() { local got; got=$(jget "$1" "$2"); [ "$got" = "$3" ] && ok || bad "$4 — state.$1[$2] = '$got', want '$3'"; }

# gain(db) matching Fireface400.gain(fromDB:): 32768 * 10^(db/20)
g() { python3 -c "import math; print(round(32768*10**($1/20)))"; }

echo "== e2e-cli against $BIN (sandbox $T)"

# --version: works without connecting at all (env unset on purpose)
OUT=$(env -u FFCTL_FAKE_HW -u FFCTL_STATE_DIR "$BIN" --version 2>&1); RC=$?
expect_rc 0 "--version exit"
echo "$OUT" | grep -qE 'ffctl [0-9]+\.[0-9]+\.[0-9]+' && ok || bad "--version output: $OUT"

# mon: route input 0 to outs 0,1 at 0 dB
run mon 0
expect_rc 0 "mon exit"
expect_out "ok: input 0 -> out 0" "mon output"
expect_log "80080000 00008000" "mon wrote in0->out0 unity"
expect_log "80080090 00008000" "mon wrote in0->out1 unity"
expect_state input 0 "32768" "mon state in0->out0 = 0x8000"

# mix -6dB: relative step on the unity cell -> -6dB
run mix 0 1 -6dB
expect_rc 0 "mix exit"
expect_state input 1 "$(g -6)" "mix -6dB state"

# mix absolute hex -> exact cell value
run mix 0 2 0x4000
expect_rc 0 "mix hex exit"
expect_state input 2 "16384" "mix 0x4000 state"

# pb: playback cell (absolute — relative on a muted cell is -inf)
run pb 2 3 0x6000
expect_rc 0 "pb exit"
expect_state playback $((2*18+3)) "24576" "pb state"

# outvol -10dB: fader write at 0x80080f80 + hw amp gain (index 4, devval 16)
run outvol 0 -10dB
expect_rc 0 "outvol exit"
F0=$(g -10)
expect_log "80080f80 $(printf '%08x' "$F0")" "outvol fader write"
expect_log "801c0180 00040010" "outvol amp gain idx4 devval16"
expect_state output 0 "$F0" "outvol state"

# main: absolute first, then a RELATIVE step in a second invocation —
# proves the tracked value round-trips through state.json on disk
run main 0x8000
expect_rc 0 "main abs exit"
run main -6dB
expect_rc 0 "main -6 exit"
run main +3dB
expect_rc 0 "main +3 exit"
expect_state output 0 "$(g -3)" "main -6+3 = -3dB via persisted state"
expect_state output 1 "$(g -3)" "main writes both pair channels"

# mainmute
run mainmute on
expect_rc 0 "mainmute on"
expect_state outputMute 0 "True" "mainmute flags L"
expect_state outputMute 1 "True" "mainmute flags R"
run mainmute off
expect_rc 0 "mainmute off"

# stereo link: outvol on ch 0 must write peer ch 1
run stereo 0 on
expect_rc 0 "stereo on"
run outvol 0 -20dB
expect_rc 0 "linked outvol"
F20=$(g -23)   # tracked was -3dB; "-20dB" is a -20 relative step -> -23
expect_log "80080f84 $(printf '%08x' "$F20")" "stereo link writes peer fader"

# phantom: config block lands as 3 quadlet writes in the sink log
# (sink folds writeConfig into quadlets; real wire is one block write)
run phantom 1 on
expect_rc 0 "phantom exit"
expect_log "80100514 00000811" "phantom1 sets q0 bit0 (ffado vector)"
run config
expect_out "phantom1=true" "config shows phantom1"

# solo / mute / phase / mono flags
run mute 5 on
expect_rc 0 "mute exit"
expect_state inputMute 5 "True" "mute flag"
run solo 2 on
expect_rc 0 "solo exit"
expect_state inputSolo 2 "True" "solo flag"
run solo 2 off
expect_rc 0 "unsolo exit"
run phase 3 on
expect_rc 0 "phase exit"
expect_state inputPhase 3 "True" "phase flag"
run mono on
expect_rc 0 "mono exit"
expect_state monoBus "" "True" "mono flag"

# meters: fake device serves a deterministic block
run meters
expect_rc 0 "meters exit"
expect_out "phys-in :" "meters prints phys-in row"
expect_out "phys-out:" "meters prints phys-out row"
expect_out "0.0!" "meters shows 0 dB + clip flag on ch 1"

# snapshots round-trip through the filesystem
run save e2esnap
expect_rc 0 "save exit"
run snaps
expect_out "e2esnap" "snaps lists"
run mono off

# flag toggles must produce the right CELL writes, not just state flips.
# Input cell address = 0x80080000 + dest*0x90 + src*4.
run mix 5 0 0x8000          # tracked cell set while mute5 is still on
run mute 5 on
expect_last 80080014 00000000 "mute 5 zeroes in5->out0"
run mute 5 off
expect_last 80080014 00008000 "unmute 5 restores in5->out0"

run mix 3 0 0x8000
run phase 3 on
expect_last 8008000c ffff8000 "phase 3 writes negative gain"

# with in5->out0 = 0x8000 and unmuted, an unrelated solo silences it
run solo 2 on
expect_last 80080014 00000000 "solo 2 silences in5->out0"
run solo 2 off
expect_last 80080014 00008000 "unsolo restores in5->out0"

# mono sums the bus pair to (L+R)/2 non-destructively
run mix 6 0 0x8000
run mix 6 1 0
run mono on
expect_last 80080018 00004000 "mono averages in6->out0"
expect_last 800800a8 00004000 "mono averages in6->out1"
run mono off
expect_last 80080018 00008000 "mono off restores in6->out0"
expect_last 800800a8 00000000 "mono off restores in6->out1"

run load e2esnap
expect_rc 0 "load exit"
expect_state monoBus "" "True" "load restores snapshotted state"
run rmsnap e2esnap
expect_rc 0 "rmsnap exit"
run snaps
expect_out "no snapshots" "snapshot deleted"

# batch via stdin: comments + blanks skipped, one session
OUT=$(printf '# comment\n\nmon 1\nmute 7 on\n' | "$BIN" batch - 2>&1); RC=$?
expect_rc 0 "batch exit"
expect_out "ok: input 1 -> out 0" "batch ran commands"
expect_state inputMute 7 "True" "batch state persisted"

# failing fake device: apply reports failures, nonzero exit
OUT=$(FFCTL_FAKE_FAIL=1 "$BIN" apply 2>&1); RC=$?
expect_rc 1 "failing device: apply nonzero"
expect_out "failed" "failing device: reports failure"

# invalid args -> usage text + exit 2
run main -3dB 9
expect_rc 2 "invalid pair exits 2"
expect_out "ffctl — RME Fireface 400" "invalid pair shows usage"
run mix 0
expect_rc 2 "missing args exits 2"
expect_out "ffctl — RME Fireface 400" "missing args shows usage"
run bogus
expect_rc 2 "unknown command exits 2"
expect_out "ffctl — RME Fireface 400" "unknown command shows usage"

# no args / --help -> usage text + exit 0
OUT=$("$BIN" 2>&1); RC=$?
expect_rc 0 "no args exits 0"
echo "$OUT" | grep -qF "ffctl — RME Fireface 400" && ok || bad "no args shows usage"
run --help
expect_rc 0 "--help exits 0"
expect_out "ffctl — RME Fireface 400" "--help shows usage"

echo
echo "== $pass passed, $fail failed"
[ "$fail" -eq 0 ]
