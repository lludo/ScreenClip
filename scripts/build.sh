#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
case "${1:-debug}" in
    debug|Debug) configuration=Debug ;;
    release|Release) configuration=Release ;;
    *) printf '%s\n' 'Usage: bash scripts/build.sh [debug|release]' >&2; exit 2 ;;
esac
derived_data="$PWD/build/DerivedData"
app="$derived_data/Build/Products/$configuration/ScreenClip.app"
# Normal runs use /Applications. Never replace a build product being run for diagnostics.
for process_id in $(pgrep -x ScreenClip || true); do
    executable_path="$(ps -ww -p "$process_id" -o comm= || true)"
    if [[ "$executable_path" == "$app/Contents/MacOS/ScreenClip" ]]; then
        printf '%s\n' 'Quit the running build product before rebuilding. Use scripts/run.sh to run the installed app.' >&2
        exit 1
    fi
done
arguments=(
    -project ScreenClip.xcodeproj -scheme ScreenClip -configuration "$configuration"
    -destination "platform=macOS,arch=$(uname -m)"
    -derivedDataPath "$derived_data" -clonedSourcePackagesDirPath "$PWD/.local/XcodePackages"
    ONLY_ACTIVE_ARCH=YES
)
if [[ -n "${SCREENCLIP_SIGNING_IDENTITY:-}" ]]; then
    arguments+=("CODE_SIGN_IDENTITY=$SCREENCLIP_SIGNING_IDENTITY")
fi
xcodebuild "${arguments[@]}" build
codesign --verify --deep --strict "$app"
printf 'Built %s\n' "$app"
