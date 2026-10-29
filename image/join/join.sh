#!/bin/sh
# Joins the downloaded parts and verifies them. Works on macOS, Linux and
# Android Termux (pkg install xz-utils coreutils).
#   sh join.sh            -> SurfaceTouchMac-*.img.xz  (Rufus can flash this directly)
#   sh join.sh --unpack   -> also decompresses to the raw .img (for EtchDroid / dd)
set -eu
cd "$(dirname "$0")"
first="$(ls *.img.xz.part-aaa 2>/dev/null | head -1)"
[ -n "$first" ] || { echo "no *.img.xz.part-aaa found in $(pwd)"; exit 1; }
base="${first%.part-aaa}"
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"; else SHA="shasum -a 256"; fi

echo "checking parts..."
$SHA -c SHA256SUMS-parts.txt
echo "joining into $base ..."
cat "$base".part-* > "$base"
echo "checking joined file..."
$SHA -c SHA256SUMS-xz.txt
if [ "${1:-}" = "--unpack" ]; then
  echo "decompressing (needs ~$(( $(wc -c < "$base") / 1000000000 + 2 ))+ GB free; the raw image is larger)..."
  xz -dk "$base"
  $SHA -c SHA256SUMS-img.txt
fi
echo "OK"
