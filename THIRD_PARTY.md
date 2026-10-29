# Third-party components

| Component | Source | Licence | How it is used |
|---|---|---|---|
| BigSurface (+ BigSurfaceHIDDriver, VoodooGPIO, VoodooInput, VoodooSerial) | github.com/Xiashangning/BigSurface @ 8282631 | GPL-3.0 (BigSurface); see each submodule | Built from source with `kext/patches/0001-…patch` |
| IPTSDaemon | github.com/Xiashangning/IPTSDaemon @ 8e19309 | GPL-2.0-or-later | Algorithms reimplemented in `kext/IPTSKernelProcessor.hpp`; daemon built for pen only |
| iptsd | github.com/linux-surface/iptsd | GPL-2.0-or-later | Origin of the IPTSDaemon algorithms |
| TouchDeck / TouchKeys | github.com/whiteoakmedia/TouchDeck @ d24f524 | MIT (© 2024 Sebastian Hueber, © 2026 White Oak Media) | Basis of `keyboard/Sources/SurfaceTouchKeys` |
| Surface Pro 7 OpenCore EFI | github.com/balopez83/Surface-Pro-7-Hackintosh release 2.5.0 | see repository | Base config, ACPI patches and kexts, downloaded at build time |
| OpenCorePkg | github.com/acidanthera/OpenCorePkg | BSD-3-Clause | Bundled with the base EFI; `ocvalidate`/`macserial` from the matching official release |
| Lilu | github.com/acidanthera/Lilu | BSD-3-Clause | SDK for building BigSurface |
| fmt, spdlog, GSL, inih | upstream GitHub tags pinned in `iptsd/build_iptsd.sh` | MIT / MIT / MIT / BSD-3-Clause | Compiled into the pen helper |
| macOS Tahoe | Apple | Apple software licence | Downloaded from Apple at image build time, **never** stored in this public repository |
