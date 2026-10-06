#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Runs the capture benchmark in release mode. Arguments are passed through.
set -euo pipefail

if pgrep -x OBS >/dev/null 2>&1; then
    echo "Quit OBS before running the benchmark; it needs the capture device." >&2
    exit 1
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CLANG_MODULE_CACHE_PATH="$root_dir/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root_dir/.build/swift-module-cache"
exec swift run --package-path "$root_dir" --disable-sandbox -c release \
    matanyone2-benchmark "$@"
