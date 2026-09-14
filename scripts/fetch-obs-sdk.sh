#!/usr/bin/env bash
# Fetches the libobs headers matching the installed OBS version, plus the SIMDe
# headers libobs needs on arm64. Both go under .build/ and are never committed.
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
obs_app="${OBS_APP:-/Applications/OBS.app}"
sdk_dir="$root_dir/.build/obs-studio"
simde_dir="$root_dir/.build/simde"
simde_tag="v0.8.2"

if [[ -n "${OBS_VERSION:-}" ]]; then
    obs_version="$OBS_VERSION"
elif [[ -f "$obs_app/Contents/Info.plist" ]]; then
    obs_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$obs_app/Contents/Info.plist")"
else
    echo "OBS is not installed at $obs_app; set OBS_APP or OBS_VERSION." >&2
    exit 1
fi

# Clones or updates a shallow checkout of one tag.
fetch_tag() {
    local url="$1" tag="$2" dir="$3"
    if [[ -d "$dir/.git" ]] &&
        [[ "$(git -C "$dir" describe --tags --exact-match HEAD 2>/dev/null || true)" == "$tag" ]]; then
        return
    fi
    if [[ -d "$dir/.git" ]]; then
        git -C "$dir" fetch --depth 1 origin "tag" "$tag"
        git -C "$dir" checkout --detach "$tag"
    else
        git clone --depth 1 --branch "$tag" "$url" "$dir"
    fi
}

fetch_tag https://github.com/obsproject/obs-studio.git "$obs_version" "$sdk_dir"
printf 'OBS %s headers ready at %s\n' "$obs_version" "$sdk_dir"

fetch_tag https://github.com/simd-everywhere/simde.git "$simde_tag" "$simde_dir"
printf 'SIMDe %s headers ready at %s\n' "$simde_tag" "$simde_dir"
