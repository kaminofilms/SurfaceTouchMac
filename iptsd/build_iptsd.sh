#!/bin/bash
# Builds IPTSDaemon (pen helper) as one self-contained x86_64 binary:
# fmt/spdlog/GSL are used header-only, inih is compiled from source, so the
# installed daemon has no Homebrew dylib dependencies.
# macOS only. Output: iptsd/build/IPTSDaemon
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/versions.env"
OUT="$HERE/build"
SRC="$OUT/src"
rm -rf "$OUT" && mkdir -p "$SRC"

git clone --quiet "https://github.com/${IPTSDAEMON_REPO}.git" "$SRC/IPTSDaemon"
git -C "$SRC/IPTSDaemon" checkout --quiet "$IPTSDAEMON_COMMIT"
git clone --quiet --depth 1 --branch r58 https://github.com/benhoyt/inih.git "$SRC/inih"
git clone --quiet --depth 1 --branch v4.0.0 https://github.com/microsoft/GSL.git "$SRC/gsl"
git clone --quiet --depth 1 --branch 9.1.0 https://github.com/fmtlib/fmt.git "$SRC/fmt"
git clone --quiet --depth 1 --branch v1.11.0 https://github.com/gabime/spdlog.git "$SRC/spdlog"

D="$SRC/IPTSDaemon/IPTSDaemon"
FILES=$(cd "$D" && ls config/config.cpp contacts/advanced/detector.cpp contacts/basic/*.cpp contacts/finder.cpp \
        daemon/cone.cpp daemon/dft.cpp daemon/main.cpp daemon/stylus.cpp daemon/touch.cpp ipts/*.cpp)
OBJS=()
CXXFLAGS=(-std=c++20 -O2 -arch x86_64 -mmacosx-version-min=11.0 -DNDEBUG
          -DSPDLOG_HEADER_ONLY -DSPDLOG_FMT_EXTERNAL -DFMT_HEADER_ONLY
          -I "$D" -I "$D/ipts" -I "$SRC/gsl/include" -I "$SRC/fmt/include" -I "$SRC/spdlog/include" -I "$SRC/inih")
mkdir -p "$OUT/obj"
for f in $FILES; do
  o="$OUT/obj/$(echo "$f" | tr '/' '_').o"
  clang++ "${CXXFLAGS[@]}" -c "$D/$f" -o "$o"
  OBJS+=("$o")
done
clang -O2 -arch x86_64 -mmacosx-version-min=11.0 -c "$SRC/inih/ini.c" -o "$OUT/obj/ini.o"
clang++ -arch x86_64 -mmacosx-version-min=11.0 "${OBJS[@]}" "$OUT/obj/ini.o" \
  -framework IOKit -framework CoreFoundation -o "$OUT/IPTSDaemon"
codesign --force --options runtime --sign - "$OUT/IPTSDaemon"
lipo "$OUT/IPTSDaemon" -verify_arch x86_64
echo "== dynamic libraries (must be system only)"
otool -L "$OUT/IPTSDaemon"
if otool -L "$OUT/IPTSDaemon" | tail -n +2 | grep -vqE "^\s*/(usr/lib|System/Library)/"; then
  echo "ERROR: non-system dylib dependency"; exit 1
fi
echo "BUILT: $OUT/IPTSDaemon"
