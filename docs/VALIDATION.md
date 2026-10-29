# Validation and compatibility report

Evidence levels used below: **Unit** = host or CI unit tests · **Build** = compiled and
statically checked on a CI Mac · **Runtime-CI** = executed on a GitHub macOS 15 Intel
runner (a VM, not a Surface) · **Surface** = tested on a physical Surface Pro 7.
**No item has Surface-level evidence yet.** File checksums prove integrity, not that anything boots.

## macOS version decision

| Question | Answer |
|---|---|
| Newest macOS overall | macOS 27 (Apple silicon only) |
| Newest with Intel/x86_64 support | macOS Tahoe 26 (the image build takes the newest 26.x full installer from Apple's catalog) |
| Newest realistic on Surface Pro 7 | Tahoe 26, via OpenCore. The Ice Lake GPU driver is present because Apple supports the 2020 Ice Lake MacBook Pro (SMBIOS `MacBookPro16,2`) |
| Apple's 2026 touch support | Part of the Apple-silicon-only macOS 27; **not** backported. Touch here is our own implementation |

## Results

| Item | Evidence | Result |
|---|---|---|
| Kernel multitouch processor (`kext/IPTSKernelProcessor.hpp`) | Unit, ASan/UBSan | 118 checks pass: position accuracy, 10 fingers, stable IDs while pinching, touch-up on lift, palm rejection, pen blocks touch, jitter filter, orientation, 200 noise frames → 0 ghosts, 20 000 fuzzed + truncated buffers without out-of-bounds reads |
| Same code is kernel-safe | Build | Compiles freestanding with SSE/x87 disabled (no floating point, no libc/STL) |
| Patch on BigSurface | Build | Applies cleanly to pinned upstream; `BigSurface.kext` builds with Xcode 16.4, all binaries x86_64, new symbols present |
| BigSurface vs base EFI's prebuilt `BigSurface-6.6RC-Custom` | Build (symbol diff) | Identical class/method symbols apart from our additions; the only real difference was VoodooInput 1.1.7. We now bundle acidanthera VoodooInput 1.1.7 too. The prebuilt kext stays in the EFI, disabled, as a fallback |
| AirportItlwm for Tahoe (laobamac/itlwm @ 738d4c6) | Build | Builds, x86_64, limited to Darwin 25. The fork does not confirm AX201 on Tahoe |
| OpenCore config | Build | Base: balopez83 EFI 2.5.0 (`EFI_OCmodr1.0.5_r2.5.0.7z`, sha256 pinned), `config-i5.plist`. Official `ocvalidate` 1.0.5: **no issues** after removing 2 keys that exist only in the OCmod fork (`ACPI/Quirks/EnableForAll=false`, `Booter/Quirks/EnableForAll=false`). The fork's own binary is therefore not validated by its own validator |
| Kext/ACPI/driver references and load order | Build | `check_efi.py`: 0 errors (every enabled kext, SSDT and driver exists; dependencies load first) |
| SurfaceTouchKeys + setup tool unit tests | Unit (CI Mac) | 38 tests pass (layout, Shift/Caps, symbols, long-press handover, hold-repeat, focus rules incl. password and browser fields, Surface Pro 7 sizing, disk planner, hardware check) |
| Keyboard architecture/signing | Build | Universal x86_64 + arm64, minimum macOS 13, **ad-hoc signed, not notarized** |
| Keyboard behaviour | Runtime-CI | With TextEdit: opens by itself on the focused text area, synthetic taps reach the keys, 3 characters typed into the document, TextEdit stays frontmost, panel can never become key |
| Disk selection safety | Unit + Runtime-CI | Fixtures: internal SSD with USB + SD attached; renumbered disks (SSD = disk3); dual boot → correct EFI. Refuses: booted from USB, two internal disks, missing EFI, EFI not first, multi-store APFS, virtual disk. On the CI Mac (not a Surface) `check-hardware` and `install-efi --dry-run` both refuse with exit 2 |
| Pen helper (IPTSDaemon) | Build | Self-contained x86_64 binary, only system libraries; configured with finger touch disabled |
| Setup package | Build | Builds; **unsigned** (no Developer ID Installer certificate) |
| USB image build | not yet run | Needs the private repository (contains Apple software) |
| Booting, touch, Wi-Fi, audio, graphics, sleep/wake on the Surface | **Surface: not tested** | — |

## Touch behaviour delivered

| Gesture | Mechanism |
|---|---|
| Tap, double tap, hold ≈1 s = right click, drag/select | BigSurface digitizer → pointer events (emulation) |
| Two-finger scroll, pinch zoom, 3/4-finger gestures | VoodooInput simulated trackpad (emulation) |
| Coordinate mapping/rotation | BigSurface reads the framebuffer transform; `stmorient` boot-arg for panel orientation fixes |
| Palm rejection | Kernel processor drops palm-shaped blobs and fingers next to them (`stmpalm=0` disables) |
| Contact cancellation | Lifted contacts get one explicit touch-up report |
| Sleep/wake | Tracker reset on sleep; multitouch mode re-sent whenever the digitizer becomes ready |
| Direct touch events to apps | **Not available**: no public direct-touch API on Intel macOS |

## Environments

| Stage | Touch | Keyboard |
|---|---|---|
| Firmware / OpenCore picker | No | Type Cover (OpenCore picks automatically) |
| FileVault unlock (if enabled) | No | Type Cover |
| macOS installer, Recovery, Setup Assistant | Yes (kernel multitouch, untested on hardware) | Type Cover or Apple's Accessibility Keyboard if offered there (unverified) |
| Login window | Yes | Apple Accessibility Keyboard (one checkbox, Lock Screen settings) |
| Desktop | Yes | SurfaceTouchKeys (after one Accessibility approval) |

## Known risks

- The base maintainer reports occasional overheating with BigSurface on recent macOS; not addressed here.
- Tahoe point updates may break kexts; the image pins whatever 26.x Apple serves at build time.
- Cameras cannot work (IPU4 has no macOS or Linux driver).
