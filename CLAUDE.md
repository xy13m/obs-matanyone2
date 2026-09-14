# obs-matanyone2

OBS Studio effect filter for Apple Silicon. Runs MatAnyone 2 video matting on
the Neural Engine through Core ML and keeps the person plus the physical props
(chair, microphone, boom arm) in the frame.

## Commands

```sh
swift build                    # Swift targets only (bridge, core, benchmark)
swift test                     # unit tests; no OBS, camera or Neural Engine needed
scripts/check-format.sh        # clang-format + swift-format, read-only
scripts/check-format.sh --fix  # rewrite in place
scripts/fetch-obs-sdk.sh       # libobs headers for the installed OBS version
scripts/export-models.sh       # Core ML models; MA2_WORKING_WIDTH/HEIGHT select the resolution
scripts/build-plugin.sh        # assemble and sign .build/plugin/obs-matanyone2-matting.plugin
scripts/install-plugin.sh      # copy into ~/Library/Application Support/obs-studio/plugins
scripts/setup-plugin.sh        # all of the above, idempotent; OBS must be closed
scripts/run-benchmark.sh       # Elgato 4K X capture benchmark; OBS must be closed
```

The C++ OBS module is compiled by `scripts/build-plugin.sh` with clang++, not
by SwiftPM. SwiftPM builds the Swift bridge (target `MatAnyone2Bridge`,
shipped as `libMatAnyone2MattingBridge.dylib` with a C ABI), the OBS-free
logic library (`MatAnyone2Core`) and the benchmark.

## Layout

- `Plugin/` — the OBS module: `src/` C++ sources, `include/obsconfig.h`,
  `Info.plist`, `data/effects`, `data/locale`, `data/models` (export target,
  ignored by git).
- `Sources/MatAnyone2Core` — pure Swift logic with no OBS or Core ML
  dependency. Everything testable lives here.
- `Sources/MatAnyone2Bridge` — C ABI over MatAnyone2Kit for the C++ module.
- `Sources/MatAnyone2Benchmark` — standalone capture benchmark.
- `Tests/` — Swift Testing suites for `MatAnyone2Core`.
- `scripts/` — build, export, install and lint scripts. All use
  `#!/usr/bin/env bash` and must stay idempotent.
- `tools/export/` — pinned Python project (uv) for the Core ML export.

## Platform lock

macOS 26 or newer, Apple Silicon only, current stable Xcode and Swift 6
language mode with strict concurrency. No backwards compatibility. Use the
newest Core ML, Vision and Metal APIs where they help, and verify each API
against current Apple documentation before relying on it.

OBS headers are pinned to the version installed at `/Applications/OBS.app`
(read from its `Info.plist` by `scripts/fetch-obs-sdk.sh`). They are fetched,
never committed.

## Rules

- No per-frame heuristics. The matte comes from the tracker seeded with the
  person and the props. The clean plate is used only during calibration to
  derive the props mask. No per-frame clean-plate difference, no geometric
  assumptions about where the microphone or chair is. A cheap safety net
  (removing tiny isolated specks) is acceptable only if measured.
- The OBS render loop must stay at 60 fps at 1080p60 regardless of matte
  throughput. Inference runs on its own thread with a latest-frame-only
  queue. Reuse GPU textures; no per-frame allocations on the render thread.
- MatAnyone2Kit is vendored as a pinned SwiftPM dependency from the fork at
  `github.com/xy13m/MatAnyone2Kit`. Changes to the kit go into the fork as
  commits and the revision in `Package.swift` is bumped. Do not copy kit
  sources into this repository.
- Models are exported by `scripts/export-models.sh` from a pinned upstream
  commit with pinned Python package versions (`tools/export/uv.lock`). Never
  commit or redistribute model files.
- Code comments, docs, commit messages and UI strings are in English. Log
  lines are prefixed `[obs-matanyone2]`.
- Every filter setting gets a description (tooltip) and a sensible default.

## Licensing

Plugin code is GPL-3.0-or-later. MatAnyone2Kit is GPL-3.0. The MatAnyone 2
weights are NTU S-Lab License 1.0, non-commercial only, and must never be
redistributed. See `NOTICE.md`.
