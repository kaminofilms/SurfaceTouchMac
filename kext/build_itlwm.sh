#!/bin/bash
# Builds AirportItlwm for macOS Tahoe (Darwin 25) from source:
# laobamac/itlwm (GPL-2.0), the fork with native Wi-Fi support on Tahoe.
# The Surface Pro 7 has an Intel AX201 (CNVi), which itlwm supports; Tahoe
# support on this adapter is NOT confirmed by the fork's authors.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"
OUT="$HERE/build-itlwm"
rm -rf "$OUT" && mkdir -p "$OUT"
git clone --quiet "https://github.com/${ITLWM_REPO}.git" "$OUT/itlwm"
cd "$OUT/itlwm"
git checkout --quiet "$ITLWM_COMMIT"
git clone --quiet https://github.com/acidanthera/MacKernelSDK.git MacKernelSDK
git -C MacKernelSDK checkout --quiet "$ITLWM_MACKERNELSDK_COMMIT"
xcodebuild -project itlwm.xcodeproj -scheme AirportItlwm-Tahoe -configuration Release \
  -derivedDataPath "$OUT/dd" ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build \
  > "$OUT/xcodebuild.log" 2>&1 || { grep -E "error:" "$OUT/xcodebuild.log" | awk 'NR<=30'; tail -30 "$OUT/xcodebuild.log"; exit 1; }
K="$(find "$OUT/dd" -type d -name 'AirportItlwm*.kext' -path '*Release*' | awk 'NR==1')"
[ -n "$K" ] || { echo "AirportItlwm kext not produced"; exit 1; }
rm -rf "$OUT/AirportItlwm-Tahoe.kext"
cp -R "$K" "$OUT/AirportItlwm-Tahoe.kext"
B="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$OUT/AirportItlwm-Tahoe.kext/Contents/Info.plist")"
lipo "$OUT/AirportItlwm-Tahoe.kext/Contents/MacOS/$B" -verify_arch x86_64
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleShortVersionString' "$OUT/AirportItlwm-Tahoe.kext/Contents/Info.plist"
echo "BUILT: $OUT/AirportItlwm-Tahoe.kext (executable $B)"
