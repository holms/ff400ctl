# ff400ctl

Control an **RME Fireface 400** mixer on modern macOS **without TotalMix** —
through the [ASFW](https://github.com/mrmidi/ASFireWire) DriverKit user client.

ASFW restores FireWire audio on macOS Tahoe (26+) by driving the OHCI
controller directly from a DriverKit extension. It streams audio to the
FF400 but does not (yet) expose RME's interactive mixer. This project fills
the gap by issuing the same asynchronous FireWire register writes that
TotalMix/FFADO use, through ASFW's raw `AsyncWrite` user-client method.

```
┌─────────────┐   IOConnectCallMethod   ┌──────────────┐   IEEE-1394   ┌───────────┐
│ ffctl /     │ ──────────────────────► │ ASFWDriver   │ ────────────► │ Fireface  │
│ FFTray.app  │  asyncWrite (sel. 9)    │ (OHCI dext)  │  quadlet write│ 400 mixer │
└─────────────┘                         └──────────────┘               └───────────┘
```

## What's inside

| Piece | Description |
|-------|-------------|
| `FFTray.app` | Menu-bar app: 18×18 input→output and playback→output routing matrix, output faders, mic/line preamp gains. ASFW "Studio Dark" style. |
| `ffctl` | CLI for scripting the same operations. |
| `fftests` | Self-contained unit-test runner (no Xcode needed). |

## Requirements

- macOS with [ASFW](https://www.asfw.net) installed and its `net.asfw.driver`
  system extension activated (tested on ASFW 0.6.0 / macOS 26).
- RME Fireface 400 on the bus.
- **No Xcode required** — Command Line Tools (`swift`) is enough.

## Build

```sh
make            # builds release ffctl + FFTray.app, ad-hoc signs both
make test       # 124 unit checks: address math, dB conversion, state codec
make install    # ffctl -> /usr/local/bin, FFTray.app -> /Applications
```

Both binaries must be signed with
`com.apple.developer.driverkit.userclient-access` = `[net.asfw.driver]`
(`Resources/entitlements.plist`). Ad-hoc signing (`codesign -s -`) is
sufficient on the machine where ASFW runs — the Makefile does it for you.

## Usage

### FFTray.app

Menu-bar slider icon → click:

- **Inputs / Playback** segmented tabs — one matrix row per source channel,
  one column per output channel (1–6 = Analog 1-6, 7–8 = Phones, 9–10 = SPDIF,
  11–18 = ADAT). Click a cell to toggle the crosspoint between mute and 0 dB.
- **INPUTS → bus** — per-input send faders into the selected monitor-bus
  pair, with **M** (mute), **S** (exclusive solo) and **Ø** (phase invert)
  chips per channel, and a **MONO** switch that sums the pair to (L+R)/2
  (inputs and playback, non-destructive).
- **OUTPUTS** — 18 master faders in stereo pairs with per-channel **M**
  (they also sync the FF400's hardware amp-gain register, like TotalMix
  does). The **ST** chip links a pair into one fader — TotalMix's stereo
  button.
- **Mic 1/2** — preamp gain 0–65 dB + **48V** phantom toggles;
  **In 3/4** — line gain + **PAD**/**INST** toggles.
  All four write the 3-quadlet device config block at `0x80100514`.
- **Re-apply mix** — rewrites all tracked cells (mixer RAM is volatile —
  the unit restores its flash-stored mix on every power cycle); output
  amp gains are re-derived from the faders rather than replayed raw.
- **Save state** — persists the intended mix to
  `~/Library/Application Support/ff400ctl/state.json`.

### ffctl

Full reference: **[CLI.md](CLI.md)** — every command, channel numbering,
gain syntax, automation recipes and file locations. Quick taste:

```sh
ffctl mon 0 0 1          # input 1 -> analog outs 1,2 at 0 dB
ffctl mix 0 0 -6dB       # one input fader cell
ffctl outvol 0 -3dB      # output master fader (relative step)
ffctl phantom 1 on       # +48V on mic input 1
ffctl mute 0 on          # mute input 1 on all outputs
ffctl save vocal         # snapshot the whole mix state
ffctl load vocal         # restore + apply it
ffctl batch script.txt   # run many commands over one session
ffctl state --json       # machine-readable state for scripts
```

## How it works

The FF400 has no AV/C or vendor-commands for mixing — it exposes raw
**register RAM**. Protocol recovered from the open-source
[FFADO](https://ffado.org) drivers (`src/rme/fireface_hw.cpp`), which RME
historically cooperated with:

| Register | Address | Purpose |
|----------|---------|---------|
| mixer RAM | `0x80080000` | live matrix, one quadlet per crosspoint |
| output faders | `0x80080f80` | 18 master faders inside mixer RAM |
| gain register | `0x801c0180` | hardware amp gains `(index<<16)\|devval` |
| channel mute | `0x801c0000` | 28-quadlet PCM fetch mask |
| output rec | `0x801c0080` | 28-quadlet output record flags |
| config block | `0x80100514` | 3 quadlets, write-only: phantom, pads, inst, levels, clock |
| meter block | `0x80100000` | ~648-byte level readback (needs working reads — see below) |

**Config block** (`0x80100514`, 3 quadlets, block write / selector 45):
phantom `q0` bits `0x01`/0x80 (mic 1/2), pads `0x100`/`0x02` (in 3/4),
instrument `0x200`/`0x04`, in/out/phones reference levels in `q0`/`q1`,
clock + sync + SPDIF opts + fixed `0x1e|0x80000000|0x04000000` in `q2`.
Encoding ported from FFADO `set_hardware_params` / ASFW `EncodeConfig`.

**Channel flags** (TotalMix semantics, software-side like FFADO):
mute writes 0 but keeps the tracked fader value; phase invert writes the
*negative* of the gain (with FFADO's `0 → -1` glitch workaround); solo is
exclusive and applies to the monitor bus pair only; mono is a true L+R
sum — both cells of the monitor pair carry the (L+R)/2 average (inputs
and playback), and it's non-destructive: stored cells are never modified,
so switching mono off restores the original stereo image.

**Matrix addressing** (FF400, `block = 0x48`):

```
input    src→dest:  0x80080000 + dest*0x90 + src*4
playback src→dest:  0x80080000 + dest*0x90 + src*4 + 0x48
output   ch fader:  0x80080f80 + ch*4
gain value: 0x8000 = 0 dB, 0x10000 = +6 dB, 0 = mute
             (dB = 20·log10(val/32768))
```

**Wire format**: registers are little-endian quadlets written to node
`0xffc0` at 48-bit offset `0x0000:xxxxxxxx` — plain quadlet async writes
through `IOConnectCallMethod` selector 9 (`kMethodAsyncWrite`), after the
same open handshake the ASFW app performs (map memory type 0 + register
status listener, selector 10).

### Known limitations / notes for the ASFW author

- **Reads don't complete.** User-client async *reads* issue fine but the
  AR response never gets matched (`AwaitingAR → TimedOut`), while
  driver-internal reads work. Writes only need the ack, so they land
  reliably (`ackComplete`) — which is why this tool is write-oriented and
  tracks mixer state in software, like FFADO's GUI does. Fixing this
  would also unlock **hardware meters**: per Takashi Sakamoto's ALSA
  `firewire-fireface-protocols`, the FF400 exposes a ~648-byte level
  block at `0x80100000` (inputs/stream/outputs, −90…0 dBFS, step 0x100,
  overload bits) via one block read.
- **Multiple OHCI services** are possible; `ffctl`/`FFTray` write on every
  `ASFWDriver` connection and treat the write as applied if any
  transaction completes. The stray writes on the wrong bus fail with
  `evt_missing_ack` harmlessly.
- **Don't flood transactions.** Rapid read bursts wedge the FF400's async
  response engine (driver Configure then times out → audio stalls until
  power cycle). Keep write bursts small; this tool writes ≤ ~40
  transactions per operation with verification polling in between.
- Mixer RAM is **volatile** — power cycle reverts to the flash-stored mix.
- A proper integration would be an **RME control provider** inside ASFW's
  Device Controls model (see `documentation/controls-rollout.md`), sharing
  this register map — happy to upstream the protocol bits.

## Safety

Writes go to live mixer RAM. A wrong value can blast an input at 0 dB into
an output or mute playback — recoverable, but start with `ffctl mon` at a
sensible level. Nothing here writes the unit's flash, so a power cycle
always restores the stored configuration.

## Credits

- Protocol: [FFADO project](https://ffado.org) `src/rme/` (J. Woithe et al.)
- Driver path: [ASFireWire](https://github.com/mrmidi/ASFireWire) by mrmidi
- UI style: ASFW Audio Analyzer "Studio Dark" theme
