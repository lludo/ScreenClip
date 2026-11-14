#!/bin/bash
set -euo pipefail
if [[ $# != 1 ]]; then
    printf '%s\n' 'Usage: bash scripts/install.sh /path/to/ScreenClip.app' >&2
    exit 2
fi
app="$1"
destination=/Applications/ScreenClip.app
if [[ ! -d "$app" || "$app" == "$destination" ]]; then
    printf '%s\n' 'Supply the Xcode-built app, not the installed copy.' >&2; exit 1
fi
identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
[[ "$identifier" == com.screenclip.app ]] || { printf '%s\n' 'This is not a ScreenClip app bundle.' >&2; exit 1; }
codesign --verify --deep --strict "$app"
signature=$(codesign -dvv "$app" 2>&1)
if ! [[ "$signature" == *Authority=* ]]; then
    printf '%s\n' 'Configure an Apple Development certificate in Config/LocalSigning.xcconfig before installing. Ad-hoc builds do not retain screen permissions across rebuilds.' >&2
    exit 1
fi
# Stage and verify before asking the running app to quit. No queue data is copied or removed.
staging=$(mktemp -d /Applications/.ScreenClip-install.XXXXXX)
cleanup() {
    if [[ -d "$staging/Previous.app" && ! -e "$destination" ]]; then
        if ! mv "$staging/Previous.app" "$destination"; then
            printf 'Previous app retained at %s\n' "$staging/Previous.app" >&2
            return
        fi
    fi
    rm -rf "$staging"
}
trap cleanup EXIT
ditto "$app" "$staging/ScreenClip.app"
codesign --verify --deep --strict "$staging/ScreenClip.app"
for process_id in $(pgrep -x ScreenClip || true); do
    executable_path="$(ps -ww -p "$process_id" -o comm= || true)"
    [[ "$executable_path" == */ScreenClip.app/Contents/MacOS/ScreenClip ]] || continue
    bundle="${executable_path%/Contents/MacOS/ScreenClip}"
    /usr/bin/osascript - "$bundle" <<'APPLESCRIPT'
on run paths
    with timeout of 5 seconds
        tell application (item 1 of paths) to quit
    end timeout
end run
APPLESCRIPT
    for ((attempt=0;attempt<25;attempt++)); do
        kill -0 "$process_id" 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 "$process_id" 2>/dev/null; then
        printf '%s\n' 'ScreenClip is still running. Save any capture and finish or cancel active work before installing.' >&2
        exit 1
    fi
done
if [[ -e "$destination" ]]; then mv "$destination" "$staging/Previous.app"; fi
if ! mv "$staging/ScreenClip.app" "$destination"; then
    if [[ -d "$staging/Previous.app" ]]; then mv "$staging/Previous.app" "$destination"; fi
    exit 1
fi
printf 'Installed %s\n' "$destination"
