#!/bin/bash
# Builds the bootable USB image (raw GPT disk) on a macOS runner.
#
#   partition 1  EFI           OpenCore for the Surface Pro 7 (unique SMBIOS)
#   partition 2  SURFACESETUP  FAT32: SurfaceTouchMac-Setup.pkg + instructions
#   partition 3  Install macOS Tahoe   (Apple's createinstallmedia, full offline installer)
#
# Inputs (env): PAYLOAD_DIR (unzipped public payload: EFI/, SurfaceTouchMac-Setup.pkg, macserial)
# Output: image/out/  parts, checksums, logs
#
# Contains Apple software: run only in a PRIVATE repository / on your own Mac,
# never publish the output publicly.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"
: "${PAYLOAD_DIR:?set PAYLOAD_DIR}"
OUT="$HERE/out"
WORK="${WORK:-$HERE/work}"
LOG="$OUT/image-build.log"
PART_SIZE="${PART_SIZE:-500m}"      # < 512 MiB per part
mkdir -p "$OUT" "$WORK"
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }
DEV=""
cleanup() { [ -n "$DEV" ] && hdiutil detach "$DEV" -force >/dev/null 2>&1 || true; }
trap cleanup EXIT

say "== macOS installer (Apple software update catalog)"
python3 -I "$HERE/fetch_installer.py" --major "$MACOS_MAJOR" --download "$WORK" > "$OUT/installer.json" 2> >(tee -a "$LOG" >&2)
cat "$OUT/installer.json" | tee -a "$LOG"
VERSION="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' "$OUT/installer.json")"
BUILD="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["build"])' "$OUT/installer.json")"
say "== verify Apple signature of InstallAssistant.pkg"
pkgutil --check-signature "$WORK/InstallAssistant.pkg" | tee -a "$LOG"
pkgutil --check-signature "$WORK/InstallAssistant.pkg" | grep -q "Apple Inc." || { say "NOT signed by Apple"; exit 1; }
shasum -a 256 "$WORK/InstallAssistant.pkg" | tee -a "$LOG"

say "== expand installer app"
sudo installer -pkg "$WORK/InstallAssistant.pkg" -target / | tee -a "$LOG"
rm -f "$WORK/InstallAssistant.pkg"
APP="$(ls -d /Applications/Install\ macOS*.app | head -1)"
say "installer app: $APP"
CIM="$APP/Contents/Resources/createinstallmedia"
[ -x "$CIM" ] || { say "createinstallmedia missing"; exit 1; }
APP_MB=$(du -sm "$APP" | cut -f1)

say "== raw GPT image"
IMG="$WORK/SurfaceTouchMac-macOS${VERSION}.img"
SIZE_MB=$(( APP_MB + 200 + 1024 + 1536 ))   # app + EFI + setup + slack
rm -f "$IMG"
mkfile -n "${SIZE_MB}m" "$IMG"
DEV="$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount "$IMG" | head -1 | awk '{print $1}')"
say "attached $IMG as $DEV (${SIZE_MB} MB)"
# Safety: only ever partition the disk image we just attached
diskutil info -plist "$DEV" | plutil -extract VirtualOrPhysical raw - | grep -qx Virtual || { say "$DEV is not a virtual disk image; abort"; exit 1; }
sudo diskutil partitionDisk "$DEV" GPT FAT32 SURFACESETUP 1g JHFS+ STMINSTALL R | tee -a "$LOG"
diskutil list "$DEV" | tee -a "$LOG"
EFI_PART="${DEV}s1"
[ "$(diskutil info -plist "$EFI_PART" | plutil -extract Content raw -)" = "EFI" ] || { say "s1 is not EFI"; exit 1; }

say "== createinstallmedia (Apple)"
sudo "$CIM" --volume /Volumes/STMINSTALL --nointeraction | tee -a "$LOG"
rm -rf "$APP" 2>/dev/null || sudo rm -rf "$APP"

say "== OpenCore with a unique SMBIOS identity"
cp -R "$PAYLOAD_DIR/EFI" "$WORK/EFI"
CFG="$WORK/EFI/OC/config.plist"
MODEL="$(/usr/libexec/PlistBuddy -c 'Print :PlatformInfo:Generic:SystemProductName' "$CFG")"
chmod +x "$PAYLOAD_DIR/macserial"
LINE="$("$PAYLOAD_DIR/macserial" -m "$MODEL" -n 1 | head -1)"
SERIAL="$(echo "$LINE" | awk -F' \\| ' '{print $1}' | tr -d ' ')"
MLB="$(echo "$LINE" | awk -F' \\| ' '{print $2}' | tr -d ' ')"
[ -n "$SERIAL" ] && [ -n "$MLB" ] || { say "macserial failed"; exit 1; }
/usr/libexec/PlistBuddy -c "Set :PlatformInfo:Generic:SystemSerialNumber $SERIAL" "$CFG"
/usr/libexec/PlistBuddy -c "Set :PlatformInfo:Generic:MLB $MLB" "$CFG"
/usr/libexec/PlistBuddy -c "Set :PlatformInfo:Generic:SystemUUID $(uuidgen)" "$CFG"
plutil -replace PlatformInfo.Generic.ROM -data "$(head -c 6 /dev/urandom | base64)" "$CFG"
say "SMBIOS $MODEL serial ****${SERIAL: -4} (full values only inside the image)"
python3 -I "$ROOT/efi/check_efi.py" "$WORK/EFI" --forbid-placeholder --require-kext BigSurface.kext | tee -a "$LOG"
[ -x "$PAYLOAD_DIR/ocvalidate" ] && { chmod +x "$PAYLOAD_DIR/ocvalidate"; "$PAYLOAD_DIR/ocvalidate" "$CFG" | tee -a "$LOG"; }
sudo diskutil mount "$EFI_PART" | tee -a "$LOG"
EFI_MNT="$(diskutil info -plist "$EFI_PART" | plutil -extract MountPoint raw -)"
sudo cp -R "$WORK/EFI" "$EFI_MNT/"
sync
sudo diskutil unmount "$EFI_PART"

say "== setup partition"
SETUP_MNT=/Volumes/SURFACESETUP
cp "$PAYLOAD_DIR/SurfaceTouchMac-Setup.pkg" "$SETUP_MNT/"
cp "$ROOT/docs/AFTER-INSTALL.txt" "$SETUP_MNT/READ ME FIRST.txt"
( cd "$SETUP_MNT" && shasum -a 256 SurfaceTouchMac-Setup.pkg > SHA256SUMS.txt )
sync

say "== filesystem checks"
INSTALL_PART="$(diskutil list -plist "$DEV" | python3 -c 'import plistlib,sys; d=plistlib.load(sys.stdin.buffer); p=d["AllDisksAndPartitions"][0]["Partitions"]; print([x["DeviceIdentifier"] for x in p if x.get("VolumeName","").startswith("Install macOS")][0])')"
SETUP_PART="${DEV}s2"
say "install partition: $INSTALL_PART"
for v in "$INSTALL_PART" "$SETUP_PART"; do sudo diskutil unmount "$v" | tee -a "$LOG"; done
sudo fsck_msdos -n "${EFI_PART}" | tee -a "$LOG"
sudo fsck_msdos -n "${SETUP_PART}" | tee -a "$LOG"
sudo fsck_hfs -n "${INSTALL_PART}" | tee -a "$LOG"
say "== partition table"
sudo gpt -r show "$DEV" | tee -a "$LOG" || diskutil list "$DEV" | tee -a "$LOG"
hdiutil detach "$DEV" | tee -a "$LOG"
DEV=""

say "== checksums, compression, split (< 512 MiB parts)"
BASE="$(basename "$IMG")"
( cd "$WORK" && shasum -a 256 "$BASE" ) | tee "$OUT/SHA256SUMS-img.txt" | tee -a "$LOG"
cd "$OUT"
xz -T0 -6 -c "$IMG" | split -b "$PART_SIZE" -a 3 - "${BASE}.xz.part-"
rm -f "$IMG"
shasum -a 256 "${BASE}.xz.part-"* > SHA256SUMS-parts.txt
say "parts: $(ls "${BASE}.xz.part-"* | wc -l | tr -d ' ')"
say "== verify reassembly: join -> xz -d -> sha256 must equal the image"
JOINED_SHA="$(cat "${BASE}.xz.part-"* | xz -dc | shasum -a 256 | awk '{print $1}')"
IMG_SHA="$(awk '{print $1}' SHA256SUMS-img.txt)"
cat "${BASE}.xz.part-"* | shasum -a 256 | awk -v n="${BASE}.xz" '{print $1"  "n}' > SHA256SUMS-xz.txt
if [ "$JOINED_SHA" = "$IMG_SHA" ]; then say "reassembly OK ($IMG_SHA)"; else say "REASSEMBLY MISMATCH"; exit 1; fi
largest=$(ls -l "${BASE}.xz.part-"* | awk '{print $5}' | sort -n | tail -1)
[ "$largest" -lt 536870912 ] || { say "a part exceeds 512 MiB"; exit 1; }
cat > image-info.json <<JSON
{"macos_version": "$VERSION", "macos_build": "$BUILD", "image": "$BASE", "image_sha256": "$IMG_SHA",
 "compressed": "${BASE}.xz", "parts": $(ls "${BASE}.xz.part-"* | wc -l | tr -d ' '), "smbios_model": "$MODEL"}
JSON
cat image-info.json | tee -a "$LOG"
say "DONE"
