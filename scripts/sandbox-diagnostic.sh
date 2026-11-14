#!/bin/bash
# Builds a tiny app, ad-hoc signs it with an App Sandbox entitlement set, and runs it.
# Denials inside the sandboxed process are findings. This script fails only when the
# diagnostic itself cannot be built or signed. It is not a ScreenClip build configuration.
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
work="$root/build/sandbox-diagnostic"
app="$work/SandboxDiag.app"
rm -rf "$work"
mkdir -p "$app/Contents/MacOS"
echo "host=$(sw_vers -productVersion) $(uname -m)"
swiftc -parse-as-library -O -o "$app/Contents/MacOS/SandboxDiag" "$root/scripts/sandbox-diagnostic.swift"
cat > "$app/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SandboxDiag</string>
  <key>CFBundleIdentifier</key><string>com.mirageteam.screenclip.sandboxdiag</string>
  <key>CFBundleName</key><string>SandboxDiag</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - \
  --identifier com.mirageteam.screenclip.sandboxdiag \
  --entitlements "$root/scripts/sandbox-diagnostic.entitlements" \
  "$app"
echo "signed_entitlements<<END"
codesign -d --entitlements :- "$app" 2>/dev/null || true
echo "END"
set +e
"$app/Contents/MacOS/SandboxDiag"
status=$?
set -e
printf 'process_exit=%s\n' "$status"
