#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Applies SurfaceTouchMac's changes to the base config.plist, printing each one.

 * enables our source-built BigSurface.kext (+ plugins) and disables the base
   EFI's prebuilt BigSurface-6.6RC-Custom.kext (kept on disk as a fallback)
 * adds AirportItlwm-Tahoe.kext limited to Darwin 25 (macOS Tahoe)
"""
import plistlib
import sys

cfg_path, itlwm_exec = sys.argv[1], sys.argv[2]
cfg = plistlib.load(open(cfg_path, "rb"))
kadd = cfg["Kernel"]["Add"]

ours, custom = [], []
for e in kadd:
    bp = e.get("BundlePath", "")
    if bp == "BigSurface.kext" or bp.startswith("BigSurface.kext/"):
        ours.append(e)
    elif bp.startswith("BigSurface-6.6RC-Custom.kext"):
        custom.append(e)
if not ours or not custom:
    raise SystemExit(f"unexpected base config: ours={len(ours)} custom={len(custom)} BigSurface entries")
for e in custom:
    if e.get("Enabled"):
        print(f"disable {e['BundlePath']} (base EFI prebuilt, kept as fallback)")
    e["Enabled"] = False
for e in ours:
    if not e.get("Enabled"):
        print(f"enable  {e['BundlePath']} (SurfaceTouchMac source build)")
    e["Enabled"] = True
# ours must come at the same position the custom one had (after Lilu/VirtualSMC)
for e in ours:
    kadd.remove(e)
pos = kadd.index(custom[0])
for i, e in enumerate(ours):
    kadd.insert(pos + i, e)

if not any(e.get("BundlePath") == "AirportItlwm-Tahoe.kext" for e in kadd):
    kadd.append({
        "Arch": "x86_64", "BundlePath": "AirportItlwm-Tahoe.kext",
        "Comment": "SurfaceTouchMac: Intel Wi-Fi on macOS Tahoe (laobamac/itlwm)",
        "Enabled": True, "ExecutablePath": f"Contents/MacOS/{itlwm_exec}",
        "MaxKernel": "25.99.99", "MinKernel": "25.0.0", "PlistPath": "Contents/Info.plist",
    })
    print("add     AirportItlwm-Tahoe.kext (MinKernel 25.0.0, MaxKernel 25.99.99)")

q = cfg["Kernel"].get("Quirks", {})
print("Kernel quirks of note:", {k: q.get(k) for k in ("DisableIOMapper", "DisableLinkeditJettison", "AppleXcpmCfgLock", "PowerTimeoutKernelPanic") if k in q})
print("SecureBootModel:", cfg.get("Misc", {}).get("Security", {}).get("SecureBootModel"))
plistlib.dump(cfg, open(cfg_path, "wb"))
