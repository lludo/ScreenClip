#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ModuleCache .build/cache .build/config .build/security build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache"
configuration="${1:-debug}"
swift build -c "$configuration" --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
binary_dir="$(swift build -c "$configuration" --show-bin-path --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")"
app="$PWD/build/ScreenClip.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/ScreenClip" "$app/Contents/MacOS/ScreenClip"
cp Resources/Info.plist "$app/Contents/Info.plist"
xcrun swift scripts/make_icon.swift "$PWD/.build/ScreenClip.iconset"
iconutil -c icns .build/ScreenClip.iconset -o "$app/Contents/Resources/AppIcon.icns"
if [[ -n "${SCREENCLIP_SIGNING_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --entitlements Resources/ScreenClip.entitlements --sign "$SCREENCLIP_SIGNING_IDENTITY" "$app"
else
    codesign --force --sign - "$app"
fi
printf 'Built %s\n' "$app"
