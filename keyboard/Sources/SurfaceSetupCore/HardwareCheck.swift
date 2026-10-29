// SPDX-License-Identifier: GPL-3.0-or-later
// Confirms we are running on a Surface Pro 7 (not 7+) before touching disks.
// SMBIOS is spoofed by OpenCore, so the Mac model name is useless; instead we
// check the real CPU and the Surface-only drivers BigSurface publishes.

public struct HardwareFacts: Equatable {
    public var cpuBrand: String
    /// IOKit class names present in the I/O Registry
    public var ioClasses: Set<String>
    public init(cpuBrand: String, ioClasses: Set<String>) {
        self.cpuBrand = cpuBrand
        self.ioClasses = ioClasses
    }
}

public enum HardwareVerdict: Equatable {
    case surfacePro7(cpu: String)
    case rejected(String)
}

public enum HardwareCheck {
    /// Ice Lake CPUs shipped in the Surface Pro 7. The i3 has UHD graphics,
    /// which macOS cannot accelerate, so it is rejected.
    static let supportedCPUs = ["i5-1035G4", "i7-1065G7"]
    static let unsupportedCPUs = ["i3-1005G1": "Surface Pro 7 i3 (UHD graphics) has no macOS graphics acceleration"]
    /// Surface Pro 7+ uses Tiger Lake (11th gen); explicitly not supported.
    static let tigerLakeMarkers = ["-11", "1135G7", "1165G7", "1185G7", "1115G4"]

    /// Classes from BigSurface that only attach on Surface hardware.
    static let surfaceClasses: Set<String> = ["SurfaceSerialHubDriver", "IntelPreciseTouchStylusDriver",
                                              "SurfaceManagementEngineDriver"]

    public static func evaluate(_ f: HardwareFacts) -> HardwareVerdict {
        for m in tigerLakeMarkers where f.cpuBrand.contains(m) {
            return .rejected("CPU '\(f.cpuBrand)' looks like a Surface Pro 7+ (Tiger Lake); this build is for the Surface Pro 7 only")
        }
        for (cpu, why) in unsupportedCPUs where f.cpuBrand.contains(cpu) {
            return .rejected(why)
        }
        guard let cpu = supportedCPUs.first(where: { f.cpuBrand.contains($0) }) else {
            return .rejected("CPU '\(f.cpuBrand)' is not a Surface Pro 7 CPU")
        }
        let found = surfaceClasses.intersection(f.ioClasses)
        guard found.count >= 2 else {
            return .rejected("Surface hardware drivers not found (saw \(found.sorted())); is BigSurface loaded?")
        }
        return .surfacePro7(cpu: cpu)
    }
}
