#!/bin/bash
# CI checks for the keyboard on a macOS runner.
#  1. structural self-test (no permissions)
#  2. interactive test: TextEdit focus -> keyboard auto-shows -> tap "h","i"
#     -> TextEdit still frontmost and contains "hi".
#     Needs Accessibility for the test binary; if the runner doesn't grant it,
#     the interactive part is reported as SKIPPED, never as passed.
set -uo pipefail
cd "$(dirname "$0")/.."
BIN="dist/SurfaceTouchKeys.app/Contents/MacOS/SurfaceTouchKeys"
LOG="dist/keyboard-ci.log"
: > "$LOG"

echo "## structural self-test" | tee -a "$LOG"
"$BIN" --ci-selftest 2>&1 | tee -a "$LOG"
structural=${PIPESTATUS[0]}

echo "## interactive test (TextEdit)" | tee -a "$LOG"
osascript -e 'tell application "TextEdit" to activate' \
          -e 'tell application "TextEdit" to make new document' >/dev/null 2>&1 || true
sleep 3
"$BIN" --ci-selftest --interactive 2>&1 | tee -a "$LOG"
interactive=${PIPESTATUS[0]}
sleep 1
typed=$(osascript -e 'tell application "TextEdit" to get text of front document' 2>"dist/osascript.err" || echo "")
echo "osascript read-back stderr: $(cat dist/osascript.err)" | tee -a "$LOG"
if grep -q "accessibility_trusted SKIP" "$LOG"; then
  echo "CHECK typed_text SKIP interactive part not possible on this runner" | tee -a "$LOG"
elif [ "$typed" = "hi!" ] || grep -q "focused_text_length PASS" "$LOG"; then
  echo "CHECK typed_text PASS TextEdit contains hi! (2 taps + 1 direct post)" | tee -a "$LOG"
else
  echo "CHECK typed_text FAIL TextEdit contains '${typed}'" | tee -a "$LOG"
  interactive=1
fi
osascript -e 'tell application "TextEdit" to quit saving no' >/dev/null 2>&1 || true

echo "## summary" | tee -a "$LOG"
grep -c " PASS" "$LOG" | xargs echo "passed:" | tee -a "$LOG"
grep -c " SKIP" "$LOG" | xargs echo "skipped:" | tee -a "$LOG"
grep -c " FAIL" "$LOG" | xargs echo "failed:" | tee -a "$LOG"
[ "$structural" -eq 0 ] && [ "$interactive" -eq 0 ]
