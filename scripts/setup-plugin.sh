#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# One-shot setup: headers, dependencies, models, build and install. Safe to
# rerun; finished stages are skipped.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
width="${MA2_WORKING_WIDTH:-512}"
height="${MA2_WORKING_HEIGHT:-288}"

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "obs-matanyone2 requires an Apple Silicon Mac." >&2
    exit 1
fi
if [[ "$(sw_vers -productVersion | cut -d. -f1)" -lt 26 ]]; then
    echo "obs-matanyone2 requires macOS 26 or newer." >&2
    exit 1
fi
if pgrep -x OBS >/dev/null 2>&1; then
    echo "Quit OBS before running the setup." >&2
    exit 1
fi
if ! xcrun --find clang++ >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    echo "Install Xcode and its command line tools first." >&2
    exit 1
fi
if ! command -v uv >/dev/null 2>&1; then
    if ! command -v brew >/dev/null 2>&1; then
        echo "Homebrew is required to install uv: https://brew.sh" >&2
        exit 1
    fi
    brew install uv
fi

"$root_dir/scripts/fetch-obs-sdk.sh"
swift package --package-path "$root_dir" resolve
MA2_WORKING_WIDTH="$width" MA2_WORKING_HEIGHT="$height" "$root_dir/scripts/export-models.sh"
MA2_WORKING_WIDTH="$width" MA2_WORKING_HEIGHT="$height" "$root_dir/scripts/build-plugin.sh"
"$root_dir/scripts/install-plugin.sh"
