#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Installs the built bundle into the user's OBS plugins directory. The previous
# install is kept as <bundle>.previous; older backups are removed.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle_name="obs-matanyone2-matting.plugin"
source_bundle="$root_dir/.build/plugin/$bundle_name"
plugins_dir="$HOME/Library/Application Support/obs-studio/plugins"
target="$plugins_dir/$bundle_name"

if [[ ! -d "$source_bundle" ]]; then
    echo "Plugin bundle is missing. Run scripts/build-plugin.sh first." >&2
    exit 1
fi
if pgrep -x OBS >/dev/null 2>&1; then
    echo "Quit OBS before installing the plugin." >&2
    exit 1
fi

mkdir -p "$plugins_dir"
if [[ -d "$target" ]]; then
    rm -rf "$target.previous"
    mv "$target" "$target.previous"
fi
cp -R "$source_bundle" "$target"
printf 'Installed %s\n' "$target"
