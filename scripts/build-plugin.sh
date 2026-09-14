#!/usr/bin/env bash
# Builds the Swift bridge, compiles the OBS module and assembles the signed
# plugin bundle at .build/plugin/obs-matanyone2-matting.plugin.
#
# MA2_WORKING_WIDTH / MA2_WORKING_HEIGHT select which exported model set is
# bundled (default 512x288).
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
width="${MA2_WORKING_WIDTH:-512}"
height="${MA2_WORKING_HEIGHT:-288}"
obs_source="$root_dir/.build/obs-studio"
simde_source="$root_dir/.build/simde"
models_dir="$root_dir/.build/models/${width}x${height}/MatAnyone"
bridge_build="$root_dir/.build/arm64-apple-macosx/release"
bundle_name="obs-matanyone2-matting"
bundle="$root_dir/.build/plugin/$bundle_name.plugin"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$root_dir/Plugin/Info.plist")"

if [[ ! -f "$obs_source/libobs/obs-module.h" ]]; then
    echo "OBS headers are missing. Run scripts/fetch-obs-sdk.sh first." >&2
    exit 1
fi
if [[ ! -f "$simde_source/simde/x86/sse2.h" ]]; then
    echo "SIMDe headers are missing. Run scripts/fetch-obs-sdk.sh first." >&2
    exit 1
fi
if [[ ! -f "$models_dir/manifest.json" ]]; then
    echo "Models for ${width}x${height} are missing. Run scripts/export-models.sh first." >&2
    exit 1
fi

export CLANG_MODULE_CACHE_PATH="$root_dir/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root_dir/.build/swift-module-cache"
swift build --package-path "$root_dir" --disable-sandbox -c release \
    --product MatAnyone2MattingBridge

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Frameworks" \
    "$bundle/Contents/Resources/effects" "$bundle/Contents/Resources/locale" \
    "$bundle/Contents/Resources/models"
cp "$root_dir/Plugin/Info.plist" "$bundle/Contents/Info.plist"
cp "$root_dir/Plugin/data/effects/"*.effect "$bundle/Contents/Resources/effects/"
cp "$root_dir/Plugin/data/locale/"*.ini "$bundle/Contents/Resources/locale/"
cp "$bridge_build/libMatAnyone2MattingBridge.dylib" "$bundle/Contents/Frameworks/"
cp -R "$models_dir" "$bundle/Contents/Resources/models/MatAnyone"
chmod -R u+w "$bundle"

# Select the macOS SDK explicitly: a bare xcrun can pick a Command Line Tools
# SDK that is newer than the Xcode linker understands.
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
xcrun --sdk macosx clang++ \
    -std=c++23 -O2 -Wall -Wextra \
    -isysroot "$sdk_path" \
    -arch arm64 -mmacosx-version-min=26.0 \
    -bundle \
    -DPLUGIN_VERSION="\"$version\"" \
    -I "$root_dir/Plugin/include" \
    -I "$obs_source/libobs" \
    -I "$simde_source" \
    -I "$root_dir/Sources/MatAnyone2Bridge/include" \
    -F /Applications/OBS.app/Contents/Frameworks \
    -framework libobs \
    -L "$bridge_build" -lMatAnyone2MattingBridge \
    -Wl,-rpath,@loader_path/../Frameworks \
    "$root_dir"/Plugin/src/*.cpp \
    -o "$bundle/Contents/MacOS/$bundle_name"

xattr -cr "$bundle"
codesign --force --deep --sign - "$bundle"
printf 'Built %s (models %sx%s)\n' "$bundle" "$width" "$height"
