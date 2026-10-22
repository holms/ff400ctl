# ffctl — CLI Reference

`ffctl` controls the RME Fireface 400 mixer through the ASFW DriverKit
user client — no TotalMix or legacy RME driver required.

## Requirements

- ASFW 0.6.0+ installed and running (`net.asfw.driver` dext)
- `ffctl` installed via `make install` — it is ad-hoc signed with the
  `com.apple.developer.driverkit.userclient-access` entitlement, which
  is required to open the user client. Re-running `codesign` invalidates
  the signature if you edit the binary.
- The Fireface 400 powered on and detected on the bus (`node 0xffc0`)

Every command opens a user-client connection, applies the change, and
saves the tracked mixer state to
`~/Library/Application Support/ff400ctl/state.json` before exiting.
Exit code is `0` on success, `1` on failure — safe for scripting.

## Gain arguments

All commands taking a gain accept four forms:

| Form | Example | Meaning |
|------|---------|---------|
| hex | `0x8000` | raw mixer value (`0x8000` = 0 dB, `0x10000` = +6 dB, `0` = mute) |
| decimal | `32768` | raw mixer value |
| absolute dB | `-6dB` | converted to the nearest mixer value |
| relative dB | `+3dB` / `-3dB` | applied on top of the **tracked** value — for hotkey-driven volume scripts |

A relative step on a muted cell (`0`) starts from −90 dB.

## Channel numbering

All numbers are **zero-based** hardware channels:

| Range | Channels |
|-------|----------|
| in/out 0–5 | Analog 1–6 |
| in/out 6–7 | Phones L/R |
| in/out 8–9 | S/PDIF |
| in/out 10–17 | ADAT 1–8 |

So "input 1" on the front panel is `0`, "analog out 1/2" is `0 1`.

## Commands

### Routing matrix

```bash
ffctl mon [in] [outs...]     # route input -> outputs at 0 dB (default: in0 -> out0,out1)
ffctl mix <in> <out> <g>     # input -> output fader cell
ffctl pb <pb> <out> <g>      # host playback -> output fader cell (Mac audio)
ffctl outvol <ch> <g>        # output master fader (also syncs hw amp gain)
ffctl main <g> [pair]        # main volume: both channels of a stereo pair
                             # (default pair 0 = AN1/2); gain syntax like outvol
ffctl mainmute <on|off> [p]  # mute/unmute a whole stereo pair
ffctl 1to1                   # restore playback i -> out i at 0 dB
ffctl mute-all               # zero every input -> output fader cell
ffctl apply                  # re-write the entire tracked state to hardware
```

The matrix is 18×18 for inputs and 18×18 for playback. `pb` cells carry
audio coming **from the Mac** (system sound, DAW outputs); `mix` cells
carry live hardware inputs (zero-latency monitoring).

### Channel flags (TotalMix semantics)

```bash
ffctl mute <in> <on|off>     # mute input row on ALL outputs (fader kept)
ffctl solo <in> <on|off>     # exclusive solo on the monitor bus pair
ffctl phase <in> <on|off>    # phase invert (writes negative cell gain)
ffctl outmute <ch> <on|off>  # mute output master fader + amp gain
ffctl mono <on|off>          # mono-sum the monitor bus pair (L+R)/2 on both
ffctl stereo <pair> <on|off> # stereo-link an output pair (0-8:
                             # 0=AN1/2, 1=AN3/4, 2=AN5/6, 3=PHONES,
                             # 4=SPDIF, 5-8=ADAT pairs)
```

- `mute` writes 0 to hardware but keeps your fader value — unmute restores it.
- `stereo` links a pair's faders: in FFTray the two columns merge into
  one fader and writes are mirrored to both channels — TotalMix's stereo
  button. Persisted in state, honored by the tray app and `ffctl outvol`.
- `solo` is exclusive: engaging one input silences all others **on the
  monitor bus pair only** (AN1/2). Other outputs are untouched.
- `phase` writes the negative of the fader (FFADO convention). On a 0
  cell it writes −1 to avoid the hardware's transient level bump.
- `mono` sums the monitor bus pair to mono: both cells carry the (L+R)/2
  average for inputs **and** playback (Mac audio follows the monitor too).
  Stored fader values are never modified — `mono off` restores the
  stereo image exactly. The tray app watches `state.json`, so flag
  changes made here are reflected in the UI live.

### Hardware gains

```bash
ffctl gain <idx> <dB>        # preamp/output amp gain
```

| idx | Channel | Range |
|-----|---------|-------|
| 0, 1 | Mic 1, Mic 2 | 0 dB or 10–65 dB |
| 2, 3 | Input 3, Input 4 | line level |
| 4–9 | Analog outs 1–6 | 0 / −63.5 … +6 dB |
| 10, 11 | Phones L/R | |
| 12, 13 | S/PDIF out | |
| 14–21 | ADAT outs 1–8 | |

### Device config (phantom, pads, levels, clock)

```bash
ffctl phantom <1|2> <on|off> # +48V on mic input (front-panel 48V LED)
ffctl pad <3|4> <on|off>     # -20 dB pad
ffctl instr <3|4> <on|off>   # instrument (Hi-Z) mode
ffctl cfg ilevel|olevel|phlevel <logain|4dbu|10dbv>
ffctl cfg spdifpro <on|off>
ffctl cfg syncref <adat1|adat2|spdif|wclk|tco>
ffctl config                 # show the tracked config + encoded quadlets
```

⚠️ The config register (`0x80100514`) is **write-only**: every config
command rewrites the whole 3-quadlet block with the tracked values.
If your flash-stored settings differ from the defaults (+4 dBu
in/out/phones, clock master, ADAT1 sync, SPDIF pro), set them via `cfg`
first or they'll be overwritten.

### State inspection

```bash
ffctl state                  # human summary of non-zero cells + amp gains
ffctl state --json           # full tracked MixerState as JSON (pipe to jq)
ffctl --version              # print version (no device connection needed)
```

The state is *tracked software state* — the device can't be read back
through the current ASFW user-client build, so it reflects what ffctl
last wrote, not necessarily what's in the hardware after a power cycle
(use `ffctl apply` to re-push).

## Automation

### Snapshots

```bash
ffctl save <name>            # snapshot current tracked state
ffctl load <name>            # restore snapshot + applyAll to hardware
ffctl snaps                  # list snapshot names
ffctl rmsnap <name>          # delete
```

Snapshots live in `~/Library/Application Support/ff400ctl/snapshots/<name>.json`
— plain JSON, safe to hand-edit, diff, or version-control. Names are
sanitized to `[a-zA-Z0-9_-]`. `load` applies ~666 writes; it verifies
each transaction and reports failures.

### Batch scripts

```bash
ffctl batch script.txt       # run commands from a file
ffctl batch -                # …or from stdin
```

One command per line; `#` comments and blank lines ignored; all commands
share **one user-client session** (vs. one connection per `ffctl` call).
Stops on the first failed command and reports its line number.

```bash
# script.txt — "go to phones, kill the mains"
mon 0 6 7            # input 1 -> phones
outmute 0 on         # mute analog out 1
outmute 1 on         # mute analog out 2
outvol 6 -6dB        # phones down a touch
```

### Recipes

```bash
# Hotkey volume (bind in skhd / Shortcuts / BetterTouchTool)
ffctl main -3dB              # mains down (whole pair at once)
ffctl main +3dB              # mains up
ffctl outvol 0 -3dB && ffctl outvol 1 -3dB     # mains down (per channel)
ffctl outvol 0 +3dB && ffctl outvol 1 +3dB     # mains up (per channel)
ffctl mainmute on            # mute mains

# Session presets
ffctl save tracking    # mic up, phantom on, cue sends set
ffctl save mixdown     # mics muted, playback 1:1
ffctl load tracking    # one call when the vocalist arrives

# Power-on restore (launchd / login item)
ffctl load daily       # or: ffctl apply (re-pushes tracked state)

# Watch what changed
ffctl save before && ffctl state --json > /tmp/before.json
```

## Files

| Path | Contents |
|------|----------|
| `~/Library/Application Support/ff400ctl/state.json` | tracked live state |
| `~/Library/Application Support/ff400ctl/snapshots/*.json` | named presets |

## Notes for scripters

- `ffctl` does no output on success beyond `ok: …` lines — parse
  `state --json` for values, not human summaries.
- Keep write bursts moderate; a flood of async transactions can stall
  the FF400's response engine (power cycle recovers). `batch`/`load`
  issue writes sequentially with per-write verification — safe.
- Mixer RAM is volatile: after a FF400 power cycle the unit restores
  from flash. Run `ffctl apply` or `ffctl load <name>` to restore.
