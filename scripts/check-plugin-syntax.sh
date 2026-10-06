#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Compiles the OBS module with -fsyntax-only so a compile error, a warning or a
# mismatch with the bridge header fails fast. It needs only headers (run
# scripts/fetch-obs-sdk.sh first), not libobs, so it works on CI runners
# without OBS installed.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/plugin-flags.sh
source "$root_dir/scripts/lib/plugin-flags.sh"

if [[ ! -f "$root_dir/.build/obs-studio/libobs/obs-module.h" ||
    ! -f "$root_dir/.build/simde/simde/x86/sse2.h" ]]; then
    echo "OBS or SIMDe headers are missing. Run scripts/fetch-obs-sdk.sh first." >&2
    exit 1
fi

xcrun --sdk macosx clang++ -fsyntax-only -Werror "${plugin_cxx_flags[@]}" \
    "$root_dir"/Plugin/src/*.cpp
echo "Plugin sources pass the syntax check."
