# obs-matanyone2

OBS Studio effect filter for Apple Silicon. Runs MatAnyone 2 video matting on
the Neural Engine through Core ML and keeps the person plus the physical props
(chair, microphone, boom arm) in the frame.

## Commands

```sh
swift build                    # Swift targets (core, pipeline, bridge, benchmark, C++ ring tests)
swift test                     # unit tests; no OBS, camera or Neural Engine needed
swift test -c release --filter CoreMLEngineIntegrationTests   # real models when exported
swift run FrameRingTests       # C++ tests for Plugin/src/frame_ring.hpp
scripts/check-format.sh        # clang-format + swift-format, read-only
scripts/check-format.sh --fix  # rewrite in place
scripts/fetch-obs-sdk.sh       # libobs headers for the installed OBS version
scripts/export-models.sh       # Core ML models; MA2_WORKING_WIDTH/HEIGHT select the resolution
scripts/build-plugin.sh        # assemble and sign .build/plugin/obs-matanyone2-matting.plugin
scripts/install-plugin.sh      # copy into ~/Library/Application Support/obs-studio/plugins
scripts/setup-plugin.sh        # all of the above, idempotent; OBS must be closed
scripts/run-benchmark.sh       # Elgato 4K X capture benchmark; OBS must be closed
scripts/obsctl.py              # press calibration hotkeys / read status over obs-websocket
```

The C++ OBS module is compiled by `scripts/build-plugin.sh` with clang++, not
by SwiftPM. SwiftPM builds the Swift bridge (target `MatAnyone2Bridge`,
shipped as `libMatAnyone2MattingBridge.dylib` with a C ABI), the pipeline,
the OBS-free logic library and the benchmark.

## Layout

- `Plugin/` — the OBS module. `src/plugin-main.cpp` (registration,
  properties, settings, status refresh, hotkeys), `src/render.cpp`
  (GPU: downscale, staging ring, matte and overlay textures, composite,
  edge refinement passes, alignment ring), `src/frame_ring.hpp`
  (header-only alignment bookkeeping), `data/effects`, `data/locale`,
  `data/models` (export target, ignored by git).
- `Sources/MatAnyone2Core` — pure Swift, no OBS / Core ML / Vision: masks,
  morphology, connected components, plates, props mask extraction, seed
  composition, EMA, status text. Everything here has unit tests.
- `Sources/MatAnyone2Pipeline` — the worker thread (`MattingWorker`), the
  Core ML engine wrapper, Vision seeding, postprocessing, calibration
  persistence, overlay text rendering.
- `Sources/MatAnyone2BridgeABI` — the C header shared by the Swift bridge and
  the C++ module.
- `Sources/MatAnyone2Bridge` — `@_cdecl` implementation of that header.
- `Sources/MatAnyone2Benchmark` — capture benchmark driving the same worker.
- `Sources/FrameRingTests` — C++ test executable.
- `Tests/` — Swift Testing suites; the worker is tested with a fake engine,
  segmenter and clock.
- `scripts/` — build, export, install, lint and test helpers. All use
  `#!/usr/bin/env bash` and must stay idempotent.
- `tools/export/` — pinned Python project (uv) for the Core ML export.

## Runtime facts

- Working resolution comes from the models' `manifest.json` (512x288 by
  default). 768x432 exports but runs at 33 ms per step on the M4 Pro, below
  the 30 fps target.
- Calibration is stored under
  `~/Library/Application Support/obs-studio/plugin_config/obs-matanyone2-matting/calibration/<filter uuid>/`.
- The five calibration actions are hotkeys on the parent source
  (`matanyone2.capture_clean_plate` and so on); obs-websocket's
  `TriggerHotkeyByName` reaches them, which `scripts/obsctl.py` uses.
- Log lines are prefixed `[obs-matanyone2]`; every phase change logs, and a
  timing line follows every 120 predictions.

## Platform lock

macOS 26 or newer, Apple Silicon only, current stable Xcode and Swift 6
language mode with strict concurrency. No backwards compatibility. Use the
newest Core ML, Vision and Metal APIs where they help, and verify each API
against current Apple documentation (or the SDK's swiftinterface) before
relying on it.

OBS headers are pinned to the version installed at `/Applications/OBS.app`
(read from its `Info.plist` by `scripts/fetch-obs-sdk.sh`). They are fetched,
never committed.

## Rules

- No per-frame heuristics. The matte comes from the tracker seeded with the
  person and the props. The clean plate is used only during calibration to
  derive the props mask. No per-frame clean-plate difference, no geometric
  assumptions about where the microphone or chair is. The only safety net
  is the speck filter in `Postprocessor`, and it is measured.
- The OBS render loop must stay at 60 fps at 1080p60 regardless of matte
  throughput. Inference runs on its own thread with a latest-frame-only
  mailbox. GPU textures are created once and reused; no per-frame
  allocations on the render thread.
- MatAnyone2Kit is vendored as a pinned SwiftPM dependency from the fork at
  `github.com/xy13m/MatAnyone2Kit` (branch `obs-matanyone2`). Changes to the
  kit go into the fork as commits and the revision in `Package.swift` is
  bumped. Do not copy kit sources into this repository.
- Models are exported by `scripts/export-models.sh` from a pinned upstream
  commit with pinned Python package versions (`tools/export/uv.lock`). Never
  commit or redistribute model files.
- Code comments, docs, commit messages and UI strings are in English.
- Every filter setting gets a description (tooltip) and a sensible default.
- Tests first: Core and Pipeline logic is written against Swift Testing
  suites; the worker's behaviour is specified through the fakes in
  `Tests/MatAnyone2PipelineTests/MattingWorkerTests.swift`.

## Licensing

Plugin code is GPL-3.0-or-later. MatAnyone2Kit is GPL-3.0. The MatAnyone 2
weights are NTU S-Lab License 1.0, non-commercial only, and must never be
redistributed. See `NOTICE.md`.
