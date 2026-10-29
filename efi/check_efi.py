#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Static checks for an OpenCore EFI folder (complements ocvalidate).

ocvalidate checks the config.plist schema for the exact OpenCore version;
this script checks that everything the config references really exists in
the EFI folder and that kext dependencies are satisfied in load order.

  check_efi.py <EFI dir> [--require-kext NAME ...] [--forbid-placeholder]
             [--manifest out.json]

Exit 0 when all checks pass.
"""
import hashlib
import json
import os
import plistlib
import sys

PLACEHOLDER = "STM-PLACEHOLDER"


def load(path):
    with open(path, "rb") as f:
        return plistlib.load(f)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def exists_ci(path):
    """FAT is case-insensitive; accept any case for the final component."""
    d, name = os.path.split(path)
    return os.path.isdir(d) and any(f.lower() == name.lower() for f in os.listdir(d))


def kext_bundle_id(kext_dir, plist_rel):
    p = os.path.join(kext_dir, plist_rel)
    if not os.path.isfile(p):
        return None, {}
    info = load(p)
    return info.get("CFBundleIdentifier"), info.get("OSBundleLibraries", {}) or {}


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    efi = argv[1]
    required = []
    forbid_placeholder = "--forbid-placeholder" in argv
    manifest_out = None
    i = 2
    while i < len(argv):
        if argv[i] == "--require-kext":
            required.append(argv[i + 1]); i += 2; continue
        if argv[i] == "--manifest":
            manifest_out = argv[i + 1]; i += 2; continue
        i += 1

    oc = os.path.join(efi, "OC")
    errors, warnings = [], []
    cfg_path = os.path.join(oc, "config.plist")
    for must in [cfg_path, os.path.join(oc, "OpenCore.efi"), os.path.join(efi, "BOOT", "BOOTx64.efi")]:
        if not exists_ci(must):
            errors.append(f"missing {os.path.relpath(must, efi)}")
    if errors:
        report(errors, warnings)
        return 1
    cfg = load(cfg_path)

    # ---- ACPI
    for e in cfg.get("ACPI", {}).get("Add", []):
        if e.get("Enabled") and not os.path.isfile(os.path.join(oc, "ACPI", e.get("Path", ""))):
            errors.append(f"ACPI/Add: {e.get('Path')} enabled but missing")

    # ---- Drivers
    for e in cfg.get("UEFI", {}).get("Drivers", []):
        if isinstance(e, dict):
            if not e.get("Enabled"):
                continue
            path = e.get("Path", "")
        else:
            path = e
        if path and not os.path.isfile(os.path.join(oc, "Drivers", path)):
            errors.append(f"UEFI/Drivers: {path} enabled but missing")

    # ---- Tools
    for e in cfg.get("Misc", {}).get("Tools", []):
        if e.get("Enabled") and not os.path.isfile(os.path.join(oc, "Tools", e.get("Path", ""))):
            errors.append(f"Misc/Tools: {e.get('Path')} enabled but missing")

    # ---- Kexts: files, bundle ids, dependency order
    loaded = {}          # bundle id -> index
    enabled_paths = []
    apple_prefixes = ("com.apple.",)
    for idx, e in enumerate(cfg.get("Kernel", {}).get("Add", [])):
        if not e.get("Enabled"):
            continue
        bp = e.get("BundlePath", "")
        enabled_paths.append(bp)
        kdir = os.path.join(oc, "Kexts", bp)
        if not os.path.isdir(kdir):
            errors.append(f"Kernel/Add: {bp} enabled but missing")
            continue
        exe = e.get("ExecutablePath", "")
        if exe and not os.path.isfile(os.path.join(kdir, exe)):
            errors.append(f"Kernel/Add: {bp}: ExecutablePath {exe} missing")
        bid, libs = kext_bundle_id(kdir, e.get("PlistPath", "Contents/Info.plist"))
        if not bid:
            errors.append(f"Kernel/Add: {bp}: Info.plist missing or has no CFBundleIdentifier")
            continue
        for lib in libs:
            if lib.startswith(apple_prefixes):
                continue
            if lib not in loaded:
                errors.append(f"Kernel/Add: {bp} ({bid}) needs {lib}, which is not loaded before it")
        loaded[bid] = idx

    for name in required:
        if not any(p == name or p.startswith(name + "/") or p.endswith("/" + name) for p in enabled_paths):
            errors.append(f"required kext {name} is not enabled in Kernel/Add")

    # ---- Placeholders (public payload must not carry real SMBIOS)
    gen = cfg.get("PlatformInfo", {}).get("Generic", {})
    serial = gen.get("SystemSerialNumber", "")
    if forbid_placeholder and (PLACEHOLDER in (serial, gen.get("MLB", ""))
                               or gen.get("SystemUUID", "") == "00000000-0000-0000-0000-000000000000"):
        errors.append("PlatformInfo/Generic still contains placeholders; SMBIOS was not generated")

    # ---- Manifest
    manifest = {"files": {}, "kexts": {}, "smbios_model": gen.get("SystemProductName", "")}
    for root, _, files in os.walk(efi):
        for fn in sorted(files):
            p = os.path.join(root, fn)
            manifest["files"][os.path.relpath(p, efi)] = sha256(p)
    for e in cfg.get("Kernel", {}).get("Add", []):
        kdir = os.path.join(oc, "Kexts", e.get("BundlePath", ""))
        plist = os.path.join(kdir, e.get("PlistPath", "Contents/Info.plist"))
        if os.path.isfile(plist):
            info = load(plist)
            manifest["kexts"][e.get("BundlePath")] = {
                "enabled": bool(e.get("Enabled")),
                "id": info.get("CFBundleIdentifier"),
                "version": info.get("CFBundleShortVersionString") or info.get("CFBundleVersion"),
                "MinKernel": e.get("MinKernel", ""),
                "MaxKernel": e.get("MaxKernel", ""),
            }
    if manifest_out:
        with open(manifest_out, "w") as f:
            json.dump(manifest, f, indent=2, sort_keys=True)

    report(errors, warnings)
    return 1 if errors else 0


def report(errors, warnings):
    for w in warnings:
        print("WARN ", w)
    for e in errors:
        print("ERROR", e)
    print(f"check_efi: {len(errors)} error(s), {len(warnings)} warning(s)")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
