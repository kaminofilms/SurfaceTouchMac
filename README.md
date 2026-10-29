# SurfaceTouchMac

macOS Tahoe 26 for the **Microsoft Surface Pro 7** (Intel Core i5-1035G4 / i7-1065G7, **not** the 7+),
with multi-touch from the very first boot and an on-screen keyboard that opens by itself.

> **Status:** builds and automated checks run in CI. **Nothing here has been tested on a
> physical Surface Pro 7 by this project yet.** See [docs/VALIDATION.md](docs/VALIDATION.md)
> for exactly what has and hasn't been verified.

## Why Tahoe 26 and not macOS 27

macOS 27 runs only on Apple silicon; it contains no Intel code to boot. OpenCore or an SMBIOS
change cannot fix that, and Apple's 2026 touch support for the Mac is part of that Apple-silicon-only
release. **macOS Tahoe 26 is the newest macOS that supports Intel**, and the Surface Pro 7's
Ice Lake graphics use the same Apple driver as the 2020 13-inch MacBook Pro, which Tahoe supports.
Touch here is our own implementation on top of the Surface drivers, **not** a backport of Apple's touch stack.

## What's in it

| Part | What it is | Where |
|---|---|---|
| Kernel multitouch | Heatmap → finger contacts processed **inside** BigSurface (integer-only port of the iptsd algorithm), so multi-touch works in the installer, Setup Assistant and login window, not only after the user-space daemon starts | `kext/` |
| OpenCore EFI | balopez83 Surface Pro 7 EFI (ACPI patches, config, kexts) with our BigSurface build, validated with the matching `ocvalidate` | `efi/` |
| SurfaceTouchKeys | Native AppKit on-screen keyboard (adapted from TouchKeys, MIT): opens on text focus, never steals focus, Caps Lock, Tab, arrows, hold-repeat | `keyboard/` |
| Setup package | Installs OpenCore to the **internal** SSD's EFI (with hardware + disk checks), the keyboard and its login item | `setup/`, `keyboard/Sources/SurfaceSetupCore` |
| Pen helper | IPTSDaemon built self-contained, configured for pen only | `iptsd/` |
| USB image | Raw GPT image: EFI + setup partition + Apple's full offline Tahoe installer | `image/` |

## How touch is delivered (honest version)

- **Fingers:** BigSurface's HID event driver turns one finger into a digitizer pointer (tap, double-tap,
  hold = right-click, drag) and 2–5 fingers into VoodooInput's simulated Magic Trackpad, so macOS performs
  trackpad gestures (scroll, pinch, Mission Control). That is **pointer/trackpad emulation**, not
  direct-touch event delivery to apps: macOS 26 has no public direct-touch API on Intel.
- **No duplicate input:** the kernel owns fingers. If IPTSDaemon connects, the kernel drops its finger
  reports and only accepts pen reports. TouchDeck's *Touch Up* is **not** used: it is a second user-space
  translator for USB HID digitizers and would produce duplicate clicks with BigSurface.

## Builds

- **Public** ([payload workflow](.github/workflows/payload.yml)): tests, BigSurface, EFI, keyboard, setup
  package. Contains no Apple software. Released as `payload-latest`.
- **Private** ([image workflow](.github/workflows/image.yml)): downloads Tahoe from Apple's
  software-update catalog (signature-checked), builds the USB image and splits it into parts under
  512 MiB. Must run in a **private** repository because the image contains Apple's macOS.

Then: [docs/JOIN-AND-FLASH.md](docs/JOIN-AND-FLASH.md) (Rufus, macOS, Android Termux) and
[docs/AFTER-INSTALL.txt](docs/AFTER-INSTALL.txt).

## Steps that stay manual (and why)

1. Booting from USB (firmware). 2. Picking/erasing the internal disk in Disk Utility and accepting
Apple's licence: Apple's installer offers no supported way to do this for you. 3. Setup Assistant
(your account). 4. Opening the setup package once: macOS cannot run it on its own, and it is not
notarized. 5. Approving Accessibility for the keyboard. 6. Turning on *Accessibility Keyboard* for
the login window. Nothing in this project edits the TCC database, disables SIP, FileVault or
passwords, or enables automatic login.

## Licences

Kernel code: GPL-2.0-or-later (derived from iptsd/IPTSDaemon), BigSurface is GPL-3.0.
Keyboard: MIT (derived from TouchDeck/TouchKeys). Setup tools and scripts: GPL-3.0-or-later.
See [THIRD_PARTY.md](THIRD_PARTY.md).
