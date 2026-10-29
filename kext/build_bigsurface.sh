#!/bin/bash
# Builds BigSurface.kext from pinned upstream source + SurfaceTouchMac patch.
# macOS + Xcode required. Output: kext/build/BigSurface.kext (+ dSYM, log)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"
WORK="$HERE/build/src"
OUT="$HERE/build"
rm -rf "$OUT" && mkdir -p "$WORK"

git clone --quiet "https://github.com/${BIGSURFACE_REPO}.git" "$WORK/BigSurface"
cd "$WORK/BigSurface"
git checkout --quiet "$BIGSURFACE_COMMIT"
git submodule update --init --quiet MacKernelSDK
for pair in "BigSurfaceHIDDriver:$BIGSURFACEHID_COMMIT" "VoodooGPIO:$VOODOOGPIO_COMMIT" \
            "VoodooInput:$VOODOOINPUT_COMMIT" "VoodooSerial:$VOODOOSERIAL_COMMIT"; do
  name="${pair%%:*}"; commit="${pair##*:}"
  git submodule update --init --quiet "Dependencies/$name"
  git -C "Dependencies/$name" fetch --quiet origin "$commit" 2>/dev/null || true
  git -C "Dependencies/$name" checkout --quiet "$commit"
done

# Apply the SurfaceTouchMac kernel multitouch change
cp "$HERE/IPTSKernelProcessor.hpp" Dependencies/BigSurfaceHIDDriver/BigSurfaceHIDDriver/IPTS/
git -C Dependencies/BigSurfaceHIDDriver apply --verbose "$HERE/patches/0001-BigSurfaceHIDDriver-kernel-multitouch.patch"

# Lilu SDK (DEBUG build provides headers + libs the project links against)
# Use the same Lilu version the EFI ships (LILU_VER from efi/build_efi.sh), else latest.
if [ -z "${LILU_VER:-}" ]; then
  LILU_VER="$(curl -fsSL https://api.github.com/repos/acidanthera/Lilu/releases/latest | python3 -c 'import json,sys;print(json.load(sys.stdin)["tag_name"])')"
fi
curl -fsSL -o /tmp/lilu.zip "https://github.com/acidanthera/Lilu/releases/download/${LILU_VER}/Lilu-${LILU_VER}-DEBUG.zip"
unzip -q -o /tmp/lilu.zip -d /tmp/lilu
cp -R /tmp/lilu/Lilu.kext Dependencies/
echo "Lilu SDK: ${LILU_VER}"

set -o pipefail
xcodebuild -project BigSurface/BigSurface.xcodeproj -scheme BigSurface -configuration Release \
  -derivedDataPath "$OUT/dd" ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=10.13 GCC_TREAT_WARNINGS_AS_ERRORS=NO \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO 2>&1 | tee "$OUT/xcodebuild.log" | grep -E "error:|warning: .*IPTSKernel|BUILD (SUCCEEDED|FAILED)" || true
KEXT="$(find "$OUT/dd" -path '*Release/BigSurface.kext' -maxdepth 6 -type d | head -1)"
[ -n "$KEXT" ] || { echo "BigSurface.kext not produced"; tail -50 "$OUT/xcodebuild.log"; exit 1; }
cp -R "$KEXT" "$OUT/BigSurface.kext"

echo "== kext checks"
for b in "$OUT/BigSurface.kext/Contents/MacOS/BigSurface" "$OUT"/BigSurface.kext/Contents/PlugIns/*.kext/Contents/MacOS/*; do
  lipo -info "$b"
  lipo "$b" -verify_arch x86_64
done
# The SurfaceTouchMac code must be inside the HID plugin
if nm -C "$OUT"/BigSurface.kext/Contents/PlugIns/BigSurfaceHIDDriver.kext/Contents/MacOS/BigSurfaceHIDDriver | grep -q "kernelTouch"; then
  echo "kernel multitouch symbols present"
else
  echo "ERROR: SurfaceTouchMac kernel multitouch code missing from BigSurfaceHIDDriver"; exit 1
fi
git -C Dependencies/BigSurfaceHIDDriver diff --stat
echo "BUILT: $OUT/BigSurface.kext"
