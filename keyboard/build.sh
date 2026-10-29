#!/bin/bash
# Builds SurfaceTouchKeys.app and stm-setup for Intel (x86_64) Macs.
# Requires macOS with Xcode command line tools. Output: keyboard/dist/
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${STM_VERSION:-0.1.0}"
BUILD="${STM_BUILD:-1}"
OUT="dist"
rm -rf "$OUT" && mkdir -p "$OUT"

# x86_64 is what the Surface Pro 7 needs; arm64 is added so the app can also
# be tried on Apple silicon (Touch on Mac not required).
swift build -c release --arch x86_64 --arch arm64
BIN="$(swift build -c release --arch x86_64 --arch arm64 --show-bin-path)"

APP="$OUT/SurfaceTouchKeys.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SurfaceTouchKeys" "$APP/Contents/MacOS/SurfaceTouchKeys"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.kaminofilms.surfacetouchkeys</string>
  <key>CFBundleName</key><string>SurfaceTouchKeys</string>
  <key>CFBundleDisplayName</key><string>SurfaceTouchKeys</string>
  <key>CFBundleExecutable</key><string>SurfaceTouchKeys</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT licensed. Based on TouchKeys (TouchDeck).</string>
  <key>NSAccessibilityUsageDescription</key>
  <string>SurfaceTouchKeys needs Accessibility access to notice when a text field is focused and to type the keys you tap. It never reads or records what you type.</string>
</dict>
</plist>
PLIST

cp "$BIN/stm-setup" "$OUT/stm-setup"

# Ad-hoc signature (NOT notarized: that needs a paid Apple Developer ID).
codesign --force --options runtime --sign - "$OUT/stm-setup"
codesign --force --options runtime --sign - --identifier com.kaminofilms.surfacetouchkeys "$APP"

echo "== architecture"
lipo -info "$APP/Contents/MacOS/SurfaceTouchKeys"
lipo -info "$OUT/stm-setup"
lipo "$APP/Contents/MacOS/SurfaceTouchKeys" -verify_arch x86_64
lipo "$OUT/stm-setup" -verify_arch x86_64
echo "== signature"
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier|Runtime" || true
codesign --verify --deep --strict "$APP"
echo "== minimum OS (x86_64 slice)"
otool -arch x86_64 -l "$APP/Contents/MacOS/SurfaceTouchKeys" | grep -A3 LC_BUILD_VERSION | grep -E "minos|sdk" || true
