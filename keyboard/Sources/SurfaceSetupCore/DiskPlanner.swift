// SPDX-License-Identifier: GPL-3.0-or-later
// Safe selection of the Surface Pro 7's internal SSD and its EFI partition.
//
// The target is derived from the *booted* macOS volume ("/") — never from a
// disk number — and is rejected unless every check passes:
//   * "/" lives on exactly one APFS physical store
//   * that store's whole disk is internal, physical, non-removable, solid
//     state, on PCI-Express/NVMe, and GPT partitioned
//   * there is exactly one internal physical non-removable disk in the system
//     (a Surface Pro 7 has one SSD; anything else is treated as ambiguous)
//   * the disk has exactly one EFI partition and it is the first partition
// Any doubt => the plan fails and nothing is written.

import Foundation

public protocol DiskInfoSource {
    /// `diskutil info -plist <id-or-path>`
    func info(_ idOrPath: String) -> [String: Any]?
    /// `diskutil list -plist <whole-disk>`
    func list(_ wholeDisk: String) -> [String: Any]?
    /// identifiers of all whole disks (`diskutil list -plist` WholeDisks)
    func wholeDisks() -> [String]
}

public struct EFIPlan: Equatable, CustomStringConvertible {
    public let wholeDisk: String
    public let efiPartition: String
    public let mediaName: String
    public let sizeBytes: Int64
    public let apfsStore: String

    public var description: String {
        "internal disk \(wholeDisk) (\(mediaName), \(sizeBytes / 1_000_000_000) GB), EFI partition \(efiPartition), APFS store \(apfsStore)"
    }
}

public enum PlanError: Error, Equatable, CustomStringConvertible {
    case rootVolumeUnknown
    case rootNotAPFS
    case multiplePhysicalStores([String])
    case storeLookupFailed(String)
    case targetNotInternal(String)
    case targetNotPhysical(String)
    case targetRemovable(String)
    case targetNotSSD(String)
    case targetWrongBus(String, String)
    case targetNotGPT(String)
    case ambiguousInternalDisks([String])
    case noEFIPartition(String)
    case multipleEFIPartitions([String])
    case efiNotFirstPartition(String)

    public var description: String {
        switch self {
        case .rootVolumeUnknown: return "cannot identify the booted volume"
        case .rootNotAPFS: return "the booted volume is not on APFS"
        case .multiplePhysicalStores(let s): return "booted volume spans several physical stores \(s); refusing"
        case .storeLookupFailed(let s): return "cannot read disk information for \(s)"
        case .targetNotInternal(let d): return "\(d) is not an internal disk (booted from external media?); refusing"
        case .targetNotPhysical(let d): return "\(d) is not a physical disk; refusing"
        case .targetRemovable(let d): return "\(d) is removable/external; refusing"
        case .targetNotSSD(let d): return "\(d) is not a solid-state disk; refusing"
        case .targetWrongBus(let d, let b): return "\(d) is on bus \(b), expected PCI-Express/NVMe; refusing"
        case .targetNotGPT(let d): return "\(d) is not GPT partitioned; refusing"
        case .ambiguousInternalDisks(let d): return "more than one internal physical disk \(d); cannot be sure which is the Surface SSD"
        case .noEFIPartition(let d): return "no EFI partition on \(d)"
        case .multipleEFIPartitions(let p): return "several EFI partitions \(p); refusing"
        case .efiNotFirstPartition(let p): return "EFI partition \(p) is not the first partition; refusing"
        }
    }
}

public enum DiskPlanner {
    static let acceptedBuses: Set<String> = ["PCI-Express", "PCI", "NVMe", "Apple Fabric"]

    static func bool(_ d: [String: Any], _ k: String) -> Bool? { d[k] as? Bool }
    static func str(_ d: [String: Any], _ k: String) -> String? { d[k] as? String }

    /// Checks shared by "is this the internal SSD" decisions.
    static func validateInternalSSD(_ id: String, _ d: [String: Any]) -> PlanError? {
        if bool(d, "Internal") != true { return .targetNotInternal(id) }
        if str(d, "VirtualOrPhysical") != "Physical" { return .targetNotPhysical(id) }
        if bool(d, "RemovableMediaOrExternalDevice") == true || bool(d, "Ejectable") == true || bool(d, "Removable") == true {
            return .targetRemovable(id)
        }
        if bool(d, "SolidState") != true { return .targetNotSSD(id) }
        let bus = str(d, "BusProtocol") ?? "unknown"
        if !acceptedBuses.contains(bus) { return .targetWrongBus(id, bus) }
        if str(d, "Content") != "GUID_partition_scheme" { return .targetNotGPT(id) }
        return nil
    }

    public static func planEFI(_ src: DiskInfoSource) -> Result<EFIPlan, PlanError> {
        guard let root = src.info("/") else { return .failure(.rootVolumeUnknown) }
        guard let stores = root["APFSPhysicalStores"] as? [[String: Any]] else { return .failure(.rootNotAPFS) }
        let storeIDs = stores.compactMap { $0["APFSPhysicalStore"] as? String }
        guard storeIDs.count == 1, let store = storeIDs.first else {
            return .failure(.multiplePhysicalStores(storeIDs))
        }
        guard let storeInfo = src.info(store), let whole = str(storeInfo, "ParentWholeDisk") else {
            return .failure(.storeLookupFailed(store))
        }
        guard let wholeInfo = src.info(whole) else { return .failure(.storeLookupFailed(whole)) }
        if let err = validateInternalSSD(whole, wholeInfo) { return .failure(err) }

        // Every internal physical non-removable disk in the system.
        var internalDisks: [String] = []
        for d in src.wholeDisks() {
            guard let i = src.info(d) else { return .failure(.storeLookupFailed(d)) }
            if bool(i, "Internal") == true && str(i, "VirtualOrPhysical") == "Physical"
                && bool(i, "RemovableMediaOrExternalDevice") != true {
                internalDisks.append(d)
            }
        }
        if internalDisks != [whole] { return .failure(.ambiguousInternalDisks(internalDisks.sorted())) }

        // EFI partition
        guard let l = src.list(whole),
              let all = l["AllDisksAndPartitions"] as? [[String: Any]],
              let entry = all.first(where: { ($0["DeviceIdentifier"] as? String) == whole }),
              let parts = entry["Partitions"] as? [[String: Any]] else {
            return .failure(.storeLookupFailed(whole))
        }
        let efis = parts.filter { ($0["Content"] as? String) == "EFI" }.compactMap { $0["DeviceIdentifier"] as? String }
        if efis.isEmpty { return .failure(.noEFIPartition(whole)) }
        if efis.count > 1 { return .failure(.multipleEFIPartitions(efis)) }
        let efi = efis[0]
        if efi != "\(whole)s1" { return .failure(.efiNotFirstPartition(efi)) }

        return .success(EFIPlan(wholeDisk: whole, efiPartition: efi,
                                mediaName: str(wholeInfo, "MediaName") ?? "unknown",
                                sizeBytes: (wholeInfo["TotalSize"] as? NSNumber)?.int64Value ?? 0,
                                apfsStore: store))
    }
}
