#!/bin/bash
# validate_oc.sh <ocvalidate> <config.plist>
# The Surface base EFI uses the OCmod fork of OpenCore, which adds fork-only
# keys (Quirks/EnableForAll) unknown to the official validator. This runs the
# official ocvalidate of the same OpenCore version on a temporary copy with
# exactly those keys removed and prints what was removed. Exit code = ocvalidate's.
set -euo pipefail
OCV="$1"; CFG="$2"
TMP="$(mktemp -t ocv).plist"
trap 'rm -f "$TMP"' EXIT
python3 -I - "$CFG" "$TMP" <<'PY'
import plistlib, sys
FORK_KEYS = {"EnableForAll"}
cfg = plistlib.load(open(sys.argv[1], "rb"))
removed = []
def walk(node, path):
    if isinstance(node, dict):
        for k in list(node):
            if k in FORK_KEYS:
                removed.append(f"{path}/{k}={node[k]!r}")
                del node[k]
            else:
                walk(node[k], f"{path}/{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, f"{path}[{i}]")
walk(cfg, "")
plistlib.dump(cfg, open(sys.argv[2], "wb"))
print("fork-only keys removed for the official validator:", len(removed))
for r in removed:
    print("  ", r)
PY
"$OCV" "$TMP"
