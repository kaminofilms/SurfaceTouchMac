#!/bin/bash
# Compares the base EFI's prebuilt "BigSurface-6.6RC-Custom.kext" (no public
# source) with our source build, so the differences are visible before
# replacing it: bundle ids/versions/dependencies per plugin, IOKit personalities
# and exported class/method symbols.
set -uo pipefail
A="$1"   # custom (base EFI)
B="$2"   # ours
for k in "$A" "$B"; do
  echo "################ $(basename "$k")"
  find "$k" -name Info.plist -path '*Contents/Info.plist' | sort | while read -r p; do
    d="$(dirname "$(dirname "$p")")"
    echo "== ${d#$k}"
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$p" 2>/dev/null | tr '\n' ' '; echo
    plutil -extract OSBundleLibraries json -o - "$p" 2>/dev/null; echo
    plutil -extract IOKitPersonalities json -o - "$p" 2>/dev/null | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
  for n,v in sorted(d.items()): print("   personality", n, "->", v.get("IOClass"), v.get("IOProviderClass"), {k:v[k] for k in v if k.startswith(("STM","Surface","Max","Performance"))})
except Exception as e: pass'
  done
done
echo "################ class / method symbol differences (C++ demangled, defined symbols)"
for k in "$A" "$B"; do
  find "$k" -path '*Contents/MacOS/*' -type f | sort | while read -r bin; do
    nm -C -U "$bin" 2>/dev/null | awk '{ $1=""; $2=""; print }' | sed 's/^  //' | sort -u > "/tmp/sym.$(basename "$k").$(basename "$bin")"
  done
done
for bin in BigSurface BigSurfaceHIDDriver VoodooGPIO VoodooInput VoodooSerial; do
  fa="/tmp/sym.$(basename "$A").$bin"; fb="/tmp/sym.$(basename "$B").$bin"
  [ -f "$fa" ] && [ -f "$fb" ] || { echo "== $bin: missing in one build"; continue; }
  echo "== $bin: only in custom: $(comm -23 "$fa" "$fb" | wc -l | tr -d ' ')  only in ours: $(comm -13 "$fa" "$fb" | wc -l | tr -d ' ')"
  echo "-- only in custom (first 40)"; comm -23 "$fa" "$fb" | awk 'NR<=40'
  echo "-- only in ours (first 40)"; comm -13 "$fa" "$fb" | awk 'NR<=40'
done
echo "################ log strings only in custom (hints at its changes)"
for bin in BigSurface BigSurfaceHIDDriver VoodooInput; do
  pa="$(find "$A" -path "*Contents/MacOS/$bin" | awk 'NR==1')"; pb="$(find "$B" -path "*Contents/MacOS/$bin" | awk 'NR==1')"
  [ -n "$pa" ] && [ -n "$pb" ] || continue
  strings "$pa" | sort -u > /tmp/str.a; strings "$pb" | sort -u > /tmp/str.b
  echo "== $bin"; comm -23 /tmp/str.a /tmp/str.b | grep -E '[A-Za-z]{4}' | awk 'NR<=60'
done
