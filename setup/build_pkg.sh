#!/bin/bash
# Builds SurfaceTouchMac-Setup.pkg (macOS).
# Inputs: keyboard/dist (app + stm-setup), efi/build (EFI + macserial),
#         optional iptsd/build (IPTSDaemon + dylibs)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VERSION="${STM_VERSION:-0.1.0}"
OUT="$HERE/build"
rm -rf "$OUT" && mkdir -p "$OUT/root" "$OUT/scripts" "$OUT/resources"
R="$OUT/root"

cp -R "$HERE/payload/." "$R/"
mkdir -p "$R/Applications" "$R/Library/SurfaceTouchMac/bin"
cp -R "$ROOT/keyboard/dist/SurfaceTouchKeys.app" "$R/Applications/"
cp "$ROOT/keyboard/dist/stm-setup" "$R/Library/SurfaceTouchMac/bin/"
cp "$ROOT/efi/build/macserial" "$R/Library/SurfaceTouchMac/bin/"
cp -R "$ROOT/efi/build/EFI" "$R/Library/SurfaceTouchMac/EFI"

if [ -x "$ROOT/iptsd/build/IPTSDaemon" ]; then
  mkdir -p "$R/usr/local/bin" "$R/usr/local/lib"
  cp "$ROOT/iptsd/build/IPTSDaemon" "$R/usr/local/bin/"
  cp "$ROOT"/iptsd/build/lib*.dylib "$R/usr/local/lib/" 2>/dev/null || true
  echo "pen helper: included"
else
  rm -f "$R/Library/LaunchDaemons/com.kaminofilms.stm.iptsd.plist"
  rm -rf "$R/usr/local/iptsd"
  echo "pen helper: NOT included (IPTSDaemon was not built)"
fi
find "$R" -name .DS_Store -delete
find "$R" -type d -empty -delete

cp "$HERE/scripts/preinstall" "$HERE/scripts/postinstall" "$OUT/scripts/"
cp "$ROOT/keyboard/dist/stm-setup" "$OUT/scripts/"
chmod 755 "$OUT/scripts/"*

cat > "$OUT/resources/welcome.html" <<'HTML'
<html><body style="font-family:-apple-system;font-size:13px">
<h2>SurfaceTouchMac setup</h2>
<p>This finishes setting up macOS on your <b>Surface Pro 7</b>:</p>
<ul>
<li>Installs OpenCore onto the <b>internal SSD's EFI partition</b> so the USB drive can be removed
 (the current EFI folder is backed up to /Library/SurfaceTouchMac/Backups first).</li>
<li>Installs the SurfaceTouchKeys on-screen keyboard and starts it at every login.</li>
<li>Installs the optional pen helper, if it is included in this build.</li>
</ul>
<p>It checks that this is a Surface Pro 7 and that the internal SSD can be identified
without doubt; otherwise it stops <b>before changing anything</b>.</p>
<p>It does not read or store passwords, change privacy permissions, disable SIP or FileVault,
or turn on automatic login.</p>
</body></html>
HTML

pkgbuild --root "$R" --scripts "$OUT/scripts" --identifier com.kaminofilms.surfacetouchmac \
  --version "$VERSION" --install-location / --ownership recommended "$OUT/component.pkg"

cat > "$OUT/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>SurfaceTouchMac</title>
  <welcome file="welcome.html"/>
  <options customize="never" require-scripts="true" hostArchitectures="x86_64"/>
  <domains enable_localSystem="true"/>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" title="SurfaceTouchMac"><pkg-ref id="com.kaminofilms.surfacetouchmac"/></choice>
  <pkg-ref id="com.kaminofilms.surfacetouchmac" version="${VERSION}" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
XML
productbuild --distribution "$OUT/distribution.xml" --resources "$OUT/resources" \
  --package-path "$OUT" "$OUT/SurfaceTouchMac-Setup.pkg"

echo "== package contents"
pkgutil --payload-files "$OUT/component.pkg" | sed 's/^/  /' | awk 'NR<=80'
pkgutil --check-signature "$OUT/SurfaceTouchMac-Setup.pkg" || echo "(unsigned: no Developer ID Installer certificate)"
shasum -a 256 "$OUT/SurfaceTouchMac-Setup.pkg"
