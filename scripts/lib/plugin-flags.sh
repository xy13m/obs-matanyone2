# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by build-plugin.sh and check-plugin-syntax.sh so both compile the OBS
# module with the same flags. Expects root_dir to be set by the caller and
# defines plugin_cxx_flags (an array) for use as "${plugin_cxx_flags[@]}".

plugin_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$root_dir/Plugin/Info.plist")"

# Select the macOS SDK explicitly: a bare xcrun can pick a Command Line Tools
# SDK that is newer than the Xcode linker understands.
plugin_cxx_flags=(
    -std=c++23 -Wall -Wextra
    -isysroot "$(xcrun --sdk macosx --show-sdk-path)"
    -arch arm64 -mmacosx-version-min=27.0
    -DPLUGIN_VERSION="\"$plugin_version\""
    -I "$root_dir/Plugin/include"
    -I "$root_dir/.build/obs-studio/libobs"
    -I "$root_dir/.build/simde"
    -I "$root_dir/Sources/MatAnyone2BridgeABI/include"
)
