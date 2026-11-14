#!/bin/bash
# Notarize a Developer ID-signed Release app, staple it, and write a stapled DMG plus SHA256SUMS.
# Called by .github/workflows/release.yml after the certificate is in the keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-$PWD/build/DerivedData/Build/Products/Release/ScreenClip.app}"
out="${2:-$PWD/build}"
: "${APPLE_SIGNING_IDENTITY:?Set APPLE_SIGNING_IDENTITY to the Developer ID Application identity.}"
: "${APPLE_NOTARY_KEY:?Set APPLE_NOTARY_KEY to the App Store Connect API .p8 path.}"
: "${APPLE_NOTARY_KEY_ID:?Set APPLE_NOTARY_KEY_ID.}"
: "${APPLE_NOTARY_ISSUER_ID:?Set APPLE_NOTARY_ISSUER_ID.}"
if [[ ! -d "$app" ]]; then
    printf '%s\n' "Built app not found: $app" >&2
    exit 1
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
mkdir -p "$out"
zip="$out/ScreenClip-notarize.zip"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
xcrun notarytool submit "$zip" \
    --key "$APPLE_NOTARY_KEY" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait
xcrun stapler staple "$app"
stage=$(mktemp -d)
trap 'rm -rf "$stage" "$zip"' EXIT
cp -R "$app" "$stage/ScreenClip.app"
ln -s /Applications "$stage/Applications"
dmg="$out/ScreenClip.dmg"
rm -f "$dmg"
hdiutil create -volname ScreenClip -srcfolder "$stage" -ov -format UDZO "$dmg"
codesign --sign "$APPLE_SIGNING_IDENTITY" --timestamp "$dmg"
xcrun notarytool submit "$dmg" \
    --key "$APPLE_NOTARY_KEY" \
    --key-id "$APPLE_NOTARY_KEY_ID" \
    --issuer "$APPLE_NOTARY_ISSUER_ID" \
    --wait
xcrun stapler staple "$dmg"
(
    cd "$out"
    shasum -a 256 ScreenClip.dmg > SHA256SUMS
)
printf 'Packaged %s\n' "$dmg"
