# Changelog

All notable changes to ff400ctl. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed
- WriteCoalescer never coalesced: submissions were queued behind the
  running work, so every submit executed. Moved to FFCore and
  reimplemented with a lock + single drain loop; `waitUntilIdle()` added
- Shared coalescing keys dropped distinct writes: phantom/pad/instr all
  used key "cfg", and both channels of a stereo pair used "out.<pair>" —
  keys are now per-flag / per-channel
- Output amp-gain encoding was 2× the fader dB — now `devval = 6 - round(dB)`
  (whole dB), matching FFADO's `set_hardware_ampgain`
- Tray preamp sliders showed 0 dB regardless of hardware state; they're
  now initialized from tracked amp gains via the new `ampGainDB` inverse
- Monitor-bus change raced the hw queue (`busPair` mutated on main) and
  left stale solo-silenced cells on the old pair while the new pair was
  unsilenced — new `setBusPair` runs on the queue and rewrites affected
  cells
- Tray app only persisted state via "Save state"; every hw write now
  submits a coalesced save and `willTerminate` flushes + saves
- Hand-edited state/snapshot files with short `inputMute`/`inputPhase`/
  `inputSolo`/`outputMute`/`outputStereo` arrays crashed on index —
  `MixerState.normalized()` pads/truncates all arrays in both loaders
- UI changes while the driver was disconnected failed silently; they now
  surface "not connected — change not applied"
- `ASFWClient` leaked a mach receive port and a shared-memory mapping per
  connection; both are released in `deinit`
- `ffctl outvol` ignored the stereo link — the peer channel follows now
- Fader value labels (38pt) overlapped neighboring 30pt columns —
  columns widened to 40pt
- Re-clicking "Detach" re-centered the detached window over the user's
  position; center only on first open. The detached window is now
  Cmd-Tab reachable (`.regular` activation policy while open)
- Fader drags republished a `@Published` array per slider tick, so the
  whole panel (incl. the 324-cell matrix) re-rendered every tick — the
  visible "lag". Drag state is now view-local; hardware writes still
  stream via coalesced preview calls, and the model commits once on
  release. `MatrixView` is `Equatable` and skips unchanged re-renders
- `applyAll` replayed stale `state.ampGains` entries raw — output gains
  (indices 4–21) saved before the encoding fix re-corrupted the fader↔amp
  mapping. Re-apply now goes through `setOutputFader` which re-derives
  each output amp gain; only input gains 0–3 are replayed
- MONO was destructive (copied L cells into stored R; off couldn't
  restore; playback excluded). It's now a true TotalMix-style L+R sum —
  both monitor-pair cells carry the (L+R)/2 average for inputs and
  playback, computed in the effective-value path with stored cells
  untouched; `mono off` restores the exact stereo image

### Added
- **Detach** button: opens the mixer in a normal titled window that stays
  open while you work in other apps (the tray panel closes on focus loss)

### Changed
- Fader value labels enlarged 9pt → 11pt (wider edit field)
- `WriteCoalescer` is now public in FFCore (`Sources/FFCore/WriteCoalescer.swift`)

## [0.4.0] - 2026-10-23

### Added
- Automation commands (CLI):
  - `ffctl save|load|snaps|rmsnap` — named mix snapshots
    (TotalMix "workspace" style) stored in
    `~/Library/Application Support/ff400ctl/snapshots/`
  - `ffctl state --json` — machine-readable state export
  - `ffctl batch <file|->` — run command scripts over one user-client
    session (# comments supported, stops on first failure)
  - Relative gain steps: `ffctl outvol 0 -3dB` / `mix 0 0 +3dB` for
    hotkey-driven volume automation (new `parseGainArgument` in FFCore)
- `CLI.md` — full command reference (channel numbering, gain syntax,
  automation recipes, file locations); README trimmed to a summary + link
- Output stereo-link (TotalMix stereo button): `ST` chips on the tray
  output strip merge a pair into one fader; writes mirror to both
  channels and adopt the L value on link. `ffctl stereo <pair> on|off`,
  persisted in `MixerState.outputStereo`
- Write coalescing in FFTray: fader drags update the UI instantly and
  hardware writes drain on a serial background queue with latest-value-
  wins per key — eliminates drag lag and stale-write backlogs
- Documented the hardware meter block at `0x80100000` (readable per
  Takashi Sakamoto's ALSA implementation — blocked only by ASFW's
  user-client read path)

### Changed
- FFTray model methods are now optimistic: UI state updates immediately,
  hardware failures surface in the header instead of blocking the fader
- Larger flag chips (M/S/Ø, 48V, PAD, INST, ST, MONO): 10pt text, wider
  hit targets

### Fixed
- `parseGain`/`parseGainArgument` no longer crashes on decimal/hex input —
  `UInt32(_, radix: 0)` is invalid Swift (radix must be 2...36); explicit
  `0x` prefix handling added
- 124 unit checks: gain-arg parsing incl. relative mode, snapshot
  round-trip, stereo-link bounds + Codable persistence

## [0.3.0] - 2026-10-22

### Added
- Channel flags with TotalMix semantics (FFADO `setMixerGain` model):
  - **Mute** per input row — writes 0 to all cells, keeps tracked fader value
  - **Solo** — exclusive, applies to the monitor bus pair only
  - **Phase invert** per input row — negative cell gain, incl. FFADO's
    `0 → -1` glitch workaround for zero cells
  - **Output mute** per channel — suppresses master fader + hw amp gain
  - **MONO** bus lock — mirrors L cells into R on the selected pair
- `writeSink` test hook — `FirefaceController` is unit-testable without
  hardware (`init(testing:sink:)`)
- CLI: `mute`, `solo`, `phase`, `outmute`, `mono`
- Tray UI: M/S/Ø chips under input faders, M under outputs, MONO toggle
- 14 new unit checks (97 total) asserting exact written cell values

### Changed
- `setInputFader` / `setOutputFader` now write the *effective* cell value
  honoring mute/solo/phase flags instead of the raw gain

## [0.2.0] - 2026-10-22

### Added
- Device configuration block support — the 3-quadlet write-only register
  at `0x80100514`, encoded per FFADO `set_hardware_params` / ASFW
  `EncodeConfig`:
  - **Phantom power** (+48V) toggles for mic inputs 1/2
  - **PAD** and **INST** toggles for inputs 3/4
  - Input/output/phones reference levels, clock master, sync ref, SPDIF opts
- `AsyncBlockWrite` (selector 45) support in `ASFWClient`
- CLI: `phantom`, `pad`, `instr`, `cfg`, `config`
- Tray UI revamp: larger vertical faders, click-to-edit dB values,
  INPUTS→bus send strip with monitor-bus picker, PREAMP strip with
  mic/line gain faders, 48V/PAD/INST chips
- 13 new unit checks (83 total), incl. the FFADO reference vector `0x00020811`
- Config defaults match observed status mirror: clockMaster, spdifPro,
  syncRef=adat1

## [0.1.0] - 2026-10-22

### Added
- Initial release — RME Fireface 400 mixer control on modern macOS through
  the ASFW DriverKit user client, no TotalMix / legacy RME driver needed
- `FFCore`: `ASFWClient` (IOKit user-client wrapper, verified async writes),
  `Fireface400` (register map + matrix math ported from FFADO
  `fireface_hw.cpp`), `MixerState` (persisted state), `FirefaceController`
- `ffctl` CLI: `mon`, `mix`, `pb`, `outvol`, `gain`, `1to1`, `mute-all`,
  `apply`, `state`
- `FFTray.app` menu-bar app (ASFW Studio Dark style): 18×18 input→output /
  playback→output routing matrix, input send faders with monitor-bus
  picker, output master faders, mic/line preamp gains, click-to-type dB
  values
- `fftests`: self-contained unit-test runner (70 checks — no XCTest/Xcode
  needed)
- Makefile: build, test, install; ad-hoc codesign with the
  `net.asfw.driver` userclient-access entitlement

### Verified on hardware
- Input→output matrix writes land (`ackComplete`) — input 1 monitored to
  analog outs 1/2 confirmed by ear
- Playback 1:1 matrix, output faders, amp gains
- Correct node addressing: RME registers are 48-bit node offsets
  (`addrHigh=0`), values are little-endian quadlets

### Known limitations
- User-client async *reads* never complete (AR responses unmatched) —
  mixer state is tracked in software, like FFADO
- Mixer RAM + config register are volatile — power cycle restores flash
  state; use "Re-apply mix"
- Rapid transaction bursts can wedge the device's AR engine — keep write
  bursts small

[Unreleased]: https://github.com/holms/ff400ctl/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/holms/ff400ctl/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/holms/ff400ctl/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/holms/ff400ctl/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/holms/ff400ctl/releases/tag/v0.1.0
