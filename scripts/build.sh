#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/ModuleCache .build/cache .build/config .build/security build
export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
export SWIFT_MODULECACHE_PATH="$PWD/.build/ModuleCache"
configuration="${1:-debug}"
app="$PWD/build/ScreenClip.app"
check_running_copy() {
    for process_id in $(pgrep -x ScreenClip || true); do
        executable_path="$(ps -ww -p "$process_id" -o comm= || true)"
        if [[ "$executable_path" == "$app/Contents/MacOS/ScreenClip" ]]; then
            printf '%s\n' 'Quit build/ScreenClip.app before rebuilding it. Replacing a running app can invalidate macOS permission checks.' >&2
            exit 1
        fi
    done
}
check_running_copy
swift build -c "$configuration" --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security"
binary_dir="$(swift build -c "$configuration" --show-bin-path --disable-sandbox --cache-path "$PWD/.build/cache" --config-path "$PWD/.build/config" --security-path "$PWD/.build/security")"
check_running_copy
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary_dir/ScreenClip" "$app/Contents/MacOS/ScreenClip"
cp Resources/Info.plist "$app/Contents/Info.plist"
xcrun swift scripts/make_icon.swift "$PWD/.build/ScreenClip.iconset"
iconutil -c icns .build/ScreenClip.iconset -o "$app/Contents/Resources/AppIcon.icns"
signing_identity="${SCREENCLIP_SIGNING_IDENTITY:-}"
if [[ -z "$signing_identity" && -f Config/LocalSigning.xcconfig ]]; then
    signing_identity="$(sed -n 's/^[[:space:]]*CODE_SIGN_IDENTITY[[:space:]]*=[[:space:]]*//p' Config/LocalSigning.xcconfig | head -n 1 | sed 's/[[:space:]]*$//')"
fi
if [[ -n "$signing_identity" && "$signing_identity" != '-' ]]; then
    codesign --force --options runtime --timestamp --entitlements Resources/ScreenClip.entitlements --sign "$signing_identity" "$app"
else
    codesign --force --sign - "$app"
fi
printf 'Built %s\n' "$app"
