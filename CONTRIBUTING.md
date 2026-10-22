# Contributing

## Build & test

```sh
make            # release ffctl + FFTray.app, ad-hoc signed
make test       # standalone fftests runner (no XCTest, no hardware)
make e2e        # e2e: real ffctl binary vs a fake device (no hardware, runs in CI)
make hwtest     # hardware smoke test — needs a powered FF400; manual only
make dmg        # universal release DMG
```

`make e2e` drives the compiled `ffctl` with `FFCTL_FAKE_HW` /
`FFCTL_STATE_DIR` (see CLI.md) and asserts on register writes, stdout,
exit codes and the persisted state — it covers "a CLI option change
produces the right device writes". `fftests` covers the same for UI
actions via `MixerModel(testing:)` in the `FFModel` target.

`make hwtest` additionally proves the real user-client path works on
your machine and that a write transaction completes. It cannot read the
mixer back — the RAM is write-only through ASFW (user-client async
reads never complete), so "the device now holds X" stays unverifiable
until that's fixed upstream.

## House rules

- **One commit per change**, each with its CHANGELOG `[Unreleased]` entry.
- Tests must be **hardware-free**: drive `FirefaceController` through the
  `FirefaceController(testing:sink:)` initializer with a write-sink —
  never open a real user client in tests.
- **Hardware safety**: writes go to live mixer RAM. Never loop or flood
  async reads/writes — it can wedge the unit's AR engine until a power
  cycle. Keep bursts small and coalesce through `WriteCoalescer`.
- Keep **FFCore UI-free** — no SwiftUI/AppKit imports in there.
