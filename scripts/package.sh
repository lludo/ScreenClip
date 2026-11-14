#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build.sh release
app="$PWD/build/DerivedData/Build/Products/Release/ScreenClip.app"
ditto -c -k --sequesterRsrc --keepParent "$app" build/ScreenClip-macOS.zip
if [[ -n "${SCREENCLIP_NOTARY_PROFILE:-}" ]]; then
    if [[ -z "${SCREENCLIP_SIGNING_IDENTITY:-}" ]]; then
        printf '%s\n' 'Set SCREENCLIP_SIGNING_IDENTITY before notarizing.' >&2
        exit 1
    fi
    xcrun notarytool submit build/ScreenClip-macOS.zip --keychain-profile "$SCREENCLIP_NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    ditto -c -k --sequesterRsrc --keepParent "$app" build/ScreenClip-macOS.zip
fi
printf '%s\n' 'Packaged build/ScreenClip-macOS.zip'
