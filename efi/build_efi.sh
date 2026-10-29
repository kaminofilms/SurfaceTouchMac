#!/bin/bash
# Assembles the Surface Pro 7 OpenCore EFI:
#   base = balopez83/Surface-Pro-7-Hackintosh release (ACPI patches, config, kexts)
#   + BigSurface.kext built from source with SurfaceTouchMac kernel multitouch
#   + SMBIOS fields replaced by placeholders (real values generated per device)
# then validates it with the *matching* ocvalidate and check_efi.py.
#
# macOS runner. Needs: gh (GITHUB_TOKEN), python3, curl, unzip.
# Inputs:  kext/build/BigSurface.kext (from kext/build_bigsurface.sh)
# Outputs: efi/build/EFI, efi/build/efi-manifest.json, efi/build/efi-report.txt
#
#   build_efi.sh fetch      download + select base EFI, record Lilu/OpenCore versions
#   build_efi.sh assemble   swap in BigSurface, placeholders, validate
set -euo pipefail
MODE="${1:-all}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"
OUT="$HERE/build"
DL="$OUT/download"
REPORT="$OUT/efi-report.txt"
say() { echo "$*" | tee -a "$REPORT"; }
if [ "$MODE" = "assemble" ]; then
  [ -f "$OUT/stage.env" ] || { echo "run '$0 fetch' first"; exit 1; }
  # shellcheck disable=SC1091
  source "$OUT/stage.env"
else
rm -rf "$OUT" && mkdir -p "$DL"
: > "$REPORT"

say "== base EFI: ${BASE_EFI_REPO} ${BASE_EFI_TAG}"
gh release download "$BASE_EFI_TAG" -R "$BASE_EFI_REPO" -D "$DL" --pattern '*'
( cd "$DL" && ls -la && shasum -a 256 * ) | tee -a "$REPORT"
if [ -n "${BASE_EFI_ASSET_SHA256:-}" ]; then
  if ( cd "$DL" && shasum -a 256 * ) | grep -q "^${BASE_EFI_ASSET_SHA256} "; then
    say "base EFI asset matches pinned sha256"
  else
    say "ERROR: base EFI asset does not match pinned sha256 ${BASE_EFI_ASSET_SHA256}"; exit 1
  fi
fi
mkdir -p "$DL/unz"
for a in "$DL"/*; do
  [ -f "$a" ] || continue
  case "$a" in
    *.dmg) mnt="$(mktemp -d)"; hdiutil attach -readonly -nobrowse -mountpoint "$mnt" "$a" >/dev/null
           cp -R "$mnt"/. "$DL/unz/$(basename "$a").d/" 2>/dev/null || { mkdir -p "$DL/unz/$(basename "$a").d"; cp -R "$mnt"/. "$DL/unz/$(basename "$a").d/"; }
           hdiutil detach "$mnt" >/dev/null ;;
    *.zip|*.7z|*.tar|*.tgz|*.tar.gz|*.tar.xz|*.rar)
           mkdir -p "$DL/unz/$(basename "$a").d"
           bsdtar -xf "$a" -C "$DL/unz/$(basename "$a").d" ;;
    *) say "skipping asset $(basename "$a")" ;;
  esac
done
find "$DL/unz" -maxdepth 4 -type d | awk 'NR<=40' | tee -a "$REPORT"
# nested archives (e.g. EFI.zip inside a release zip)
find "$DL/unz" -type f \( -name '*.zip' -o -name '*.7z' \) | while read -r n; do
  mkdir -p "$n.d" && bsdtar -xf "$n" -C "$n.d"
done

say "== config candidates"
find "$DL/unz" -name '*.plist' -path '*OC*' -maxdepth 6 | grep -i config | tee -a "$REPORT"
# The OC folder that contains OpenCore.efi
OCDIR="$(dirname "$(find "$DL/unz" -name OpenCore.efi -path '*/OC/*' | awk 'NR==1')")"
[ -d "$OCDIR" ] || { say "no OpenCore.efi found in base release"; exit 1; }
EFISRC="$(dirname "$OCDIR")"
say "base EFI folder: ${EFISRC#$DL/unz/}"

# Pick the config: an explicit BASE_CONFIG (path relative to OC/) wins;
# otherwise there must be exactly one config.plist.
cfg_count=$(find "$OCDIR" -maxdepth 1 -name 'config*.plist' | wc -l | tr -d ' ')
if [ -n "${BASE_CONFIG:-}" ]; then
  CONFIG="$OCDIR/$BASE_CONFIG"
elif [ "$cfg_count" = "1" ]; then
  CONFIG="$(find "$OCDIR" -maxdepth 1 -name 'config*.plist')"
else
  say "several configs in OC/ and BASE_CONFIG not set; refusing to guess:"
  ls "$OCDIR" | tee -a "$REPORT"
  exit 1
fi
[ -f "$CONFIG" ] || { say "config $CONFIG missing"; exit 1; }
say "using config: $(basename "$CONFIG")"

mkdir -p "$OUT/EFI"
cp -R "$EFISRC/OC" "$EFISRC/BOOT" "$OUT/EFI/"
# keep only the selected config, named config.plist
find "$OUT/EFI/OC" -maxdepth 1 -name 'config*.plist' -delete
cp "$CONFIG" "$OUT/EFI/OC/config.plist"

# OpenCore version actually bundled
OCVER="$(python3 -I - "$OUT/EFI/OC/OpenCore.efi" <<'PY'
import re, sys
b = open(sys.argv[1], "rb").read()
for enc in ("ascii", "utf-16-le"):
    t = b.decode(enc, "ignore")
    m = re.search(r"(?:REL|DBG|NOP|MOD)-(\d)(\d)(\d)-\d{4}-\d{2}-\d{2}", t)
    if m:
        print(".".join(m.groups()))
        break
PY
)"
OCVER_SRC="OpenCore.efi version string"
if [ -z "$OCVER" ]; then
  # OCmod releases name the OpenCore base in the asset name, e.g. EFI_OCmodr1.0.5_r2.5.0.7z
  OCVER="$(ls "$DL" | sed -nE 's/.*OCmodr([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | awk 'NR==1')"
  OCVER_SRC="base asset name (OCmod r${OCVER})"
fi
say "bundled OpenCore: ${OCVER:-unknown} (from ${OCVER_SRC})"
[ -n "$OCVER" ] || { say "cannot determine OpenCore version"; exit 1; }

say "== official OpenCore ${OCVER} utilities (ocvalidate, macserial)"
curl -fsSL -o "$DL/oc.zip" "https://github.com/acidanthera/OpenCorePkg/releases/download/${OCVER}/OpenCore-${OCVER}-RELEASE.zip"
shasum -a 256 "$DL/oc.zip" | tee -a "$REPORT"
unzip -q -o "$DL/oc.zip" -d "$DL/oc"
cp "$DL/oc/Utilities/ocvalidate/ocvalidate" "$OUT/ocvalidate"
cp "$DL/oc/Utilities/macserial/macserial" "$OUT/macserial"
chmod +x "$OUT/ocvalidate" "$OUT/macserial"
# The bundled OpenCore.efi should be the official release binary
if cmp -s "$DL/oc/X64/EFI/OC/OpenCore.efi" "$OUT/EFI/OC/OpenCore.efi"; then
  say "OpenCore.efi matches official ${OCVER} RELEASE"
else
  say "WARN OpenCore.efi differs from official ${OCVER} RELEASE (DEBUG build or modified)"
fi

say "== Lilu version in base EFI"
LILU_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/EFI/OC/Kexts/Lilu.kext/Contents/Info.plist" 2>/dev/null || true)"
say "Lilu: ${LILU_VER:-not present}"
VSMC_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/EFI/OC/Kexts/VirtualSMC.kext/Contents/Info.plist" 2>/dev/null || true)"
say "VirtualSMC: ${VSMC_VER:-not present}"
{ echo "LILU_VER=${LILU_VER}"; echo "VSMC_VER=${VSMC_VER}"; echo "OCVER=${OCVER}"; echo "CONFIG_NAME=$(basename "$CONFIG")"; } > "$OUT/stage.env"
[ "$MODE" = "fetch" ] && { say "fetch stage done"; exit 0; }
fi
CFG="$OUT/EFI/OC/config.plist"

say "== replace BigSurface.kext with SurfaceTouchMac build"
BS="$ROOT/kext/build/BigSurface.kext"
[ -d "$BS" ] || { say "ERROR: $BS not built"; exit 1; }
[ -d "$OUT/EFI/OC/Kexts/BigSurface.kext" ] || { say "base EFI has no BigSurface.kext"; exit 1; }
if [ -d "$OUT/EFI/OC/Kexts/BigSurface-6.6RC-Custom.kext" ]; then
  bash "$ROOT/kext/compare_bigsurface.sh" "$OUT/EFI/OC/Kexts/BigSurface-6.6RC-Custom.kext" "$BS" > "$OUT/bigsurface-compare.txt" 2>&1 || true
  say "comparison with base EFI's prebuilt BigSurface-6.6RC-Custom: efi/build/bigsurface-compare.txt"
fi
rm -rf "$OUT/EFI/OC/Kexts/BigSurface.kext"
cp -R "$BS" "$OUT/EFI/OC/Kexts/BigSurface.kext"

say "== add AirportItlwm for Tahoe"
IT="$ROOT/kext/build-itlwm/AirportItlwm-Tahoe.kext"
[ -d "$IT" ] || { say "ERROR: $IT not built"; exit 1; }
cp -R "$IT" "$OUT/EFI/OC/Kexts/"
IT_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$IT/Contents/Info.plist")"
python3 -I "$HERE/edit_config.py" "$CFG" "$IT_EXEC" | tee -a "$REPORT"

say "== SMBIOS placeholders (generated per device at install time)"
MODEL="$(/usr/libexec/PlistBuddy -c 'Print :PlatformInfo:Generic:SystemProductName' "$CFG")"
say "SMBIOS model: $MODEL"
for k in SystemSerialNumber MLB; do
  /usr/libexec/PlistBuddy -c "Set :PlatformInfo:Generic:$k STM-PLACEHOLDER" "$CFG"
done
# a syntactically valid all-zero UUID is the placeholder (ocvalidate requires a UUID)
/usr/libexec/PlistBuddy -c "Set :PlatformInfo:Generic:SystemUUID 00000000-0000-0000-0000-000000000000" "$CFG"
plutil -replace PlatformInfo.Generic.ROM -data "AAAAAAAA" "$CFG"

say "== boot-args"
/usr/libexec/PlistBuddy -c 'Print :NVRAM:Add:7C436110-AB2A-4BBB-A880-FE41995C9F82:boot-args' "$CFG" | tee -a "$REPORT" || true

say "== validation: ocvalidate ${OCVER}"
# The base EFI uses the OCmod fork of OpenCore ${OCVER}. It adds fork-only keys
# (e.g. Quirks/EnableForAll) that the official validator does not know. We
# validate everything else with the official ${OCVER} ocvalidate on a copy with
# exactly those keys removed, and list what was removed.
bash "$HERE/validate_oc.sh" "$OUT/ocvalidate" "$CFG" | tee -a "$REPORT"
test "${PIPESTATUS[0]}" -eq 0
say "== validation: check_efi.py"
python3 -I "$HERE/check_efi.py" "$OUT/EFI" --require-kext BigSurface.kext --require-kext Lilu.kext --require-kext AirportItlwm-Tahoe.kext \
  --manifest "$OUT/efi-manifest.json" | tee -a "$REPORT"
test "${PIPESTATUS[0]}" -eq 0

say "== kexts (from manifest)"
python3 -I -c 'import json,sys; m=json.load(open(sys.argv[1])); [print(f"{k:60s} {v[\"version\"] or \"?\":10s} enabled={v[\"enabled\"]} MaxKernel={v[\"MaxKernel\"] or \"-\"}") for k,v in sorted(m["kexts"].items())]' "$OUT/efi-manifest.json" | tee -a "$REPORT"
echo "SMBIOS_MODEL=${MODEL}" >> "$OUT/stage.env"
say "EFI ready: $OUT/EFI"
