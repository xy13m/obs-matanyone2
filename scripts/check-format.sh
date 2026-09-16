#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Checks C++, Objective-C and Swift formatting with the Xcode toolchain's
# clang-format and swift-format. Pass --fix to rewrite files in place.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fix=0
if [[ "${1:-}" == "--fix" ]]; then
    fix=1
elif [[ $# -gt 0 ]]; then
    echo "usage: $0 [--fix]" >&2
    exit 2
fi

cd "$root_dir"
clang_files=()
while IFS= read -r -d '' file; do
    clang_files+=("$file")
done < <(find Plugin Sources -type f \( -name '*.cpp' -o -name '*.hpp' -o -name '*.h' -o -name '*.m' \) -print0)

swift_paths=(Package.swift Sources Tests)

status=0
if ((fix)); then
    xcrun clang-format -i "${clang_files[@]}"
    xcrun swift-format format --in-place --recursive "${swift_paths[@]}"
else
    xcrun clang-format --dry-run --Werror "${clang_files[@]}" || status=1
    xcrun swift-format lint --strict --recursive "${swift_paths[@]}" || status=1
fi

if ((status)); then
    echo "Formatting check failed. Run scripts/check-format.sh --fix." >&2
fi
exit "$status"
