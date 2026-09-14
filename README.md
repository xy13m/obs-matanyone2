# obs-matanyone2

An OBS Studio effect filter for Apple Silicon that removes the background
behind a person while keeping their office chair, microphone and boom arm in
the picture. It runs the MatAnyone 2 video matting model on the Neural Engine
through Core ML.

The filter is seeded once with everything that should stay visible (the
person plus the props) and then lets MatAnyone 2 track that set frame by
frame. There is no per-frame comparison against a clean plate and no
hard-coded geometry.

## Status

This repository is at the bootstrap stage: package layout, scripts, formatting
and CI are in place, and the plugin registers a passthrough filter so the
build and install pipeline can be exercised end to end. The matting pipeline,
the calibration flow and the settings reference are added with the
implementation and documented here as they land.

## Requirements

- Apple Silicon Mac. Development and measurements are done on a Mac mini
  with an M4 Pro.
- macOS 26 or newer.
- The current stable Xcode (26.x) with its command line tools. `swift`,
  `clang-format` and `swift-format` all come from the Xcode toolchain.
- OBS Studio 32.2.x installed at `/Applications/OBS.app`. The build fetches
  the libobs headers for the exact installed version.
- [`uv`](https://docs.astral.sh/uv/) for the model export. The setup script
  installs it with Homebrew when it is missing.
- Roughly 10 GB of free disk for the Python environment, the upstream
  checkout and the exported models on the first run.

## Install

Quit OBS and run:

```sh
scripts/setup-plugin.sh
```

The script is idempotent. It fetches the OBS headers matching the installed
OBS version, resolves the pinned Swift dependencies, exports and compiles the
Core ML models on the first run, builds and signs the plugin bundle, and
installs it under `~/Library/Application Support/obs-studio/plugins/`. The
first run downloads the upstream MatAnyone2 source and weights and takes much
longer than later runs.

The stages can be run one at a time:

```sh
scripts/fetch-obs-sdk.sh
swift package resolve
scripts/export-models.sh
scripts/build-plugin.sh
scripts/install-plugin.sh
```

`scripts/export-models.sh` takes the working resolution from
`MA2_WORKING_WIDTH` and `MA2_WORKING_HEIGHT` (default 512 by 288). Both must be
multiples of 16. `scripts/build-plugin.sh` reads the same variables to pick
which exported model set goes into the bundle.

## Development

```sh
swift build
swift test
scripts/check-format.sh        # clang-format and swift-format, read-only
scripts/check-format.sh --fix  # rewrite files in place
```

The unit tests run without OBS, a camera or the Neural Engine, so they also
run in GitHub Actions on a macOS runner. Anything that touches Core ML or the
Elgato capture card is measured locally with the benchmark tool:

```sh
scripts/run-benchmark.sh
```

## Licensing

The plugin source code is GPL-3.0-or-later (see `LICENSE`). The MatAnyone 2
weights are under the NTU S-Lab License 1.0 and are non-commercial only. They
are never committed to this repository; the export script downloads them on
your machine. See `NOTICE.md` for the details.
