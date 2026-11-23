#!/bin/bash
# Notarize a Developer ID-signed Release app, staple it, and write a stapled DMG, SHA256SUMS,
# and the signed Sparkle appcast.xml.
# Called by .github/workflows/release.yml after the certificate is in the keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-$PWD/build/DerivedData/Build/Products/Release/ScreenClip.app}"
out="${2:-$PWD/build}"
: "${APPLE_SIGNING_IDENTITY:?Set APPLE_SIGNING_IDENTITY to the Developer ID Application identity.}"
if [[ -n "${SCREENCLIP_NOTARY_PROFILE:-}" ]]; then
    notary_auth=(--keychain-profile "$SCREENCLIP_NOTARY_PROFILE")
else
    : "${APPLE_NOTARY_KEY:?Set APPLE_NOTARY_KEY or SCREENCLIP_NOTARY_PROFILE.}"
    : "${APPLE_NOTARY_KEY_ID:?Set APPLE_NOTARY_KEY_ID.}"
    : "${APPLE_NOTARY_ISSUER_ID:?Set APPLE_NOTARY_ISSUER_ID.}"
    notary_auth=(--key "$APPLE_NOTARY_KEY" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID")
fi
if [[ ! -d "$app" ]]; then
    printf '%s\n' "Built app not found: $app" >&2
    exit 1
fi
# Sparkle ships its helpers ad-hoc signed, and a plain xcodebuild re-signs only the framework.
# Notarization needs every nested executable signed with the Developer ID, a secure timestamp,
# and the hardened runtime, so sign them from the inside out, then re-seal the app.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$sparkle" ]]; then
    sign=(codesign --force --sign "$APPLE_SIGNING_IDENTITY" --options runtime --timestamp)
    "${sign[@]}" "$sparkle/Versions/B/XPCServices/Installer.xpc"
    "${sign[@]}" --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    "${sign[@]}" "$sparkle/Versions/B/Autoupdate"
    "${sign[@]}" "$sparkle/Versions/B/Updater.app"
    "${sign[@]}" "$sparkle"
    "${sign[@]}" --preserve-metadata=entitlements,requirements,flags "$app"
    for nested in Versions/B/Autoupdate Versions/B/Updater.app Versions/B/XPCServices/Installer.xpc; do
        # Captured first: under pipefail, grep -q exiting early would fail codesign with SIGPIPE.
        nested_signature=$(codesign -dvv "$sparkle/$nested" 2>&1 || true)
        if ! printf '%s\n' "$nested_signature" | grep -Fq "Authority=$APPLE_SIGNING_IDENTITY"; then
            printf '%s\n' "Sparkle's $nested is not signed with the Developer ID." >&2
            exit 1
        fi
    done
fi
# Sparkle offers an update only when its build number is higher than the installed one, and the
# appcast names the release by the app's version, so both must move past the published release.
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ ! -s "docs/release/v$version.md" ]]; then
    printf '%s\n' "docs/release/v$version.md is missing. Write the release notes first; they are the update's notes." >&2
    exit 1
fi
feed=$(curl -fsSL https://github.com/lludo/ScreenClip/releases/latest/download/appcast.xml 2>/dev/null || true)
if [[ -z "$feed" ]]; then
    if [[ "${SCREENCLIP_SKIP_FEED_CHECK:-}" != 1 ]]; then
        printf '%s\n' 'Could not download the published appcast to compare build numbers. Retry online, or set SCREENCLIP_SKIP_FEED_CHECK=1.' >&2
        exit 1
    fi
else
    published=$(printf '%s\n' "$feed" | sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' | head -1)
    published_version=$(printf '%s\n' "$feed" | sed -n 's:.*<sparkle\:shortVersionString>\([^<]*\)</sparkle\:shortVersionString>.*:\1:p' | head -1)
    if [[ -n "$published" && "$build" -le "$published" ]]; then
        printf '%s\n' "Build $build is not higher than the published build $published. Bump CURRENT_PROJECT_VERSION." >&2
        exit 1
    fi
    if [[ -n "$published_version" && "$version" == "$published_version" ]]; then
        printf '%s\n' "Version $version is already published. Bump MARKETING_VERSION." >&2
        exit 1
    fi
fi
codesign --verify --deep --strict "$app"
entitlements=$(codesign -d --entitlements :- "$app" 2>/dev/null || true)
if printf '%s\n' "$entitlements" | grep -q '<key>com.apple.security.app-sandbox</key>'; then
    printf '%s\n' 'Refusing to publish an App Sandbox build. Direct distribution stays unsandboxed.' >&2
    exit 1
fi
signature=$(codesign -dvv "$app" 2>&1 || true)
if ! printf '%s\n' "$signature" | grep -q 'runtime'; then
    printf '%s\n' 'The Release app is missing the hardened runtime, which notarization requires.' >&2
    exit 1
fi
if ! printf '%s\n' "$signature" | grep -Fq "Authority=$APPLE_SIGNING_IDENTITY"; then
    printf '%s\n' 'The app must be signed with the selected Developer ID Application identity.' >&2
    exit 1
fi
if printf '%s\n' "$entitlements" | grep -A1 '<key>com.apple.security.get-task-allow</key>' | grep -q '<true/>'; then
    printf '%s\n' 'Refusing to publish an app with the debugging entitlement enabled.' >&2
    exit 1
fi
mkdir -p "$out"
notarize() {
    local target="$1" receipt="$2"
    xcrun notarytool submit "$target" "${notary_auth[@]}" --wait --output-format json > "$receipt"
    python3 - "$receipt" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
print(f"Notarization {result.get('id', 'unknown')}: {result.get('status', 'unknown')}")
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept this submission; see the notarization receipt.')
PY
}
zip="$out/ScreenClip-notarize.zip"
rm -f "$zip"
stage=$(mktemp -d)
trap 'rm -rf "$stage" "$zip"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
notarize "$zip" "$out/ScreenClip-app-notarization.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
cp -R "$app" "$stage/ScreenClip.app"
ln -s /Applications "$stage/Applications"
dmg="$out/ScreenClip.dmg"
rm -f "$dmg"
hdiutil create -volname ScreenClip -srcfolder "$stage" -ov -format UDZO "$dmg"
codesign --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$dmg"
notarize "$dmg" "$out/ScreenClip-dmg-notarization.json"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
codesign --verify --strict "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
(
    cd "$out"
    shasum -a 256 ScreenClip.dmg > SHA256SUMS
)
# Sparkle appcast. The EdDSA key comes from SPARKLE_ED_PRIVATE_KEY (CI) or, locally, from the
# login keychain item that `generate_keys --account ScreenClip` created.
sparkle_bin="${SPARKLE_BIN:-$PWD/.local/XcodePackages/artifacts/sparkle/Sparkle/bin}"
if [[ ! -x "$sparkle_bin/sign_update" ]]; then
    printf '%s\n' "Sparkle's sign_update was not found in $sparkle_bin. Build with scripts/build.sh first." >&2
    exit 1
fi
if [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    ed_signature=$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sparkle_bin/sign_update" --ed-key-file - -p "$dmg")
else
    ed_signature=$("$sparkle_bin/sign_update" --account ScreenClip -p "$dmg")
fi
python3 scripts/make_appcast.py "$app" "$dmg" "$ed_signature" "$out/appcast.xml"
printf 'Packaged %s\n' "$dmg"
