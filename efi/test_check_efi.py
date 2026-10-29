#!/usr/bin/env python3
"""Tests for check_efi.py using a synthetic EFI tree."""
import os
import plistlib
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def kext(oc, name, bid, libs=None, plugin_of=None):
    base = os.path.join(oc, "Kexts", name)
    os.makedirs(os.path.join(base, "Contents", "MacOS"), exist_ok=True)
    with open(os.path.join(base, "Contents", "Info.plist"), "wb") as f:
        plistlib.dump({"CFBundleIdentifier": bid, "CFBundleShortVersionString": "1.0",
                       "OSBundleLibraries": libs or {}}, f)
    exe = os.path.join(base, "Contents", "MacOS", os.path.basename(name).replace(".kext", ""))
    open(exe, "wb").write(b"\0")


def make_efi(root, order_ok=True, missing_ssdt=False, placeholder=False):
    efi = os.path.join(root, "EFI")
    oc = os.path.join(efi, "OC")
    for d in ["ACPI", "Drivers", "Kexts", "Tools"]:
        os.makedirs(os.path.join(oc, d), exist_ok=True)
    os.makedirs(os.path.join(efi, "BOOT"), exist_ok=True)
    open(os.path.join(efi, "BOOT", "BOOTx64.efi"), "wb").write(b"x")
    open(os.path.join(oc, "OpenCore.efi"), "wb").write(b"x")
    open(os.path.join(oc, "Drivers", "OpenRuntime.efi"), "wb").write(b"x")
    if not missing_ssdt:
        open(os.path.join(oc, "ACPI", "SSDT-SURFACE.aml"), "wb").write(b"x")
    kext(oc, "Lilu.kext", "as.vit9696.Lilu")
    kext(oc, "BigSurface.kext", "com.xavier.BigSurface", {"as.vit9696.Lilu": "1.2", "com.apple.kpi.iokit": "16"})
    lilu = {"BundlePath": "Lilu.kext", "Enabled": True, "ExecutablePath": "Contents/MacOS/Lilu", "PlistPath": "Contents/Info.plist"}
    bs = {"BundlePath": "BigSurface.kext", "Enabled": True, "ExecutablePath": "Contents/MacOS/BigSurface", "PlistPath": "Contents/Info.plist"}
    cfg = {
        "ACPI": {"Add": [{"Path": "SSDT-SURFACE.aml", "Enabled": True}]},
        "UEFI": {"Drivers": [{"Path": "OpenRuntime.efi", "Enabled": True}, {"Path": "Gone.efi", "Enabled": False}]},
        "Misc": {"Tools": []},
        "Kernel": {"Add": [lilu, bs] if order_ok else [bs, lilu]},
        "PlatformInfo": {"Generic": {"SystemProductName": "MacBookAir9,1",
                                     "SystemSerialNumber": "STM-PLACEHOLDER" if placeholder else "C02ABCDEFGHI",
                                     "MLB": "x", "SystemUUID": "y"}},
    }
    with open(os.path.join(oc, "config.plist"), "wb") as f:
        plistlib.dump(cfg, f)
    return efi


def run(efi, *extra):
    p = subprocess.run([sys.executable, os.path.join(HERE, "check_efi.py"), efi, *extra],
                       capture_output=True, text=True)
    return p.returncode, p.stdout


def main():
    fails = 0
    cases = [
        ("valid EFI passes", {}, ("--require-kext", "BigSurface.kext"), 0, None),
        ("dependency order", {"order_ok": False}, (), 1, "not loaded before it"),
        ("missing SSDT", {"missing_ssdt": True}, (), 1, "SSDT-SURFACE.aml enabled but missing"),
        ("placeholder rejected", {"placeholder": True}, ("--forbid-placeholder",), 1, "placeholders"),
        ("placeholder allowed in payload", {"placeholder": True}, (), 0, None),
        ("required kext missing", {}, ("--require-kext", "AirportItlwm.kext"), 1, "AirportItlwm.kext is not enabled"),
    ]
    for name, kw, extra, want_rc, want_text in cases:
        with tempfile.TemporaryDirectory() as d:
            rc, out = run(make_efi(d, **kw), *extra)
            ok = rc == want_rc and (want_text is None or want_text in out)
            print(("PASS " if ok else "FAIL ") + name)
            if not ok:
                print(out)
                fails += 1
    print(f"{len(cases) - fails}/{len(cases)} passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
