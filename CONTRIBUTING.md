# Contributing

## Build & test

```sh
make            # release ffctl + FFTray.app, ad-hoc signed
make test       # standalone fftests runner (no XCTest, no hardware)
make dmg        # universal release DMG
```

## House rules

- **One commit per change**, each with its CHANGELOG `[Unreleased]` entry.
- Tests must be **hardware-free**: drive `FirefaceController` through the
  `FirefaceController(testing:sink:)` initializer with a write-sink —
  never open a real user client in tests.
- **Hardware safety**: writes go to live mixer RAM. Never loop or flood
  async reads/writes — it can wedge the unit's AR engine until a power
  cycle. Keep bursts small and coalesce through `WriteCoalescer`.
- Keep **FFCore UI-free** — no SwiftUI/AppKit imports in there.
