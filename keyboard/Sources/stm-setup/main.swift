// SPDX-License-Identifier: GPL-3.0-or-later
// stm-setup — used by the SurfaceTouchMac installer package (runs as root).
//
//   stm-setup check-hardware
//   stm-setup plan-efi
//   stm-setup install-efi --source <dir containing EFI/> [--dry-run]
//
// Exit codes: 0 ok, 1 usage/IO error, 2 refused for safety.

import Foundation
import SurfaceSetupCore

func run(_ path: String, _ args: [String]) -> (Int32, Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return (-1, Data()) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
}

func plist(_ data: Data) -> [String: Any]? {
    (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
}

struct LiveDisks: DiskInfoSource {
    func info(_ id: String) -> [String: Any]? {
        let (rc, d) = run("/usr/sbin/diskutil", ["info", "-plist", id])
        return rc == 0 ? plist(d) : nil
    }
    func list(_ whole: String) -> [String: Any]? {
        let (rc, d) = run("/usr/sbin/diskutil", ["list", "-plist", whole])
        return rc == 0 ? plist(d) : nil
    }
    func wholeDisks() -> [String] {
        let (rc, d) = run("/usr/sbin/diskutil", ["list", "-plist"])
        guard rc == 0, let p = plist(d) else { return [] }
        return p["WholeDisks"] as? [String] ?? []
    }
}

func log(_ s: String) {
    FileHandle.standardError.write(("stm-setup: " + s + "\n").data(using: .utf8)!)
}

func hardwareFacts() -> HardwareFacts {
    let (_, cpu) = run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"])
    var classes = Set<String>()
    for c in ["SurfaceSerialHubDriver", "IntelPreciseTouchStylusDriver", "SurfaceManagementEngineDriver"] {
        let (rc, d) = run("/usr/sbin/ioreg", ["-r", "-c", c, "-d", "1"])
        if rc == 0, !d.isEmpty { classes.insert(c) }
    }
    return HardwareFacts(cpuBrand: String(decoding: cpu, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                         ioClasses: classes)
}

func checkHardware() -> Int32 {
    switch HardwareCheck.evaluate(hardwareFacts()) {
    case .surfacePro7(let cpu):
        print("OK: Surface Pro 7 (\(cpu))")
        return 0
    case .rejected(let why):
        log("REFUSED: \(why)")
        return 2
    }
}

func planEFI() -> EFIPlan? {
    switch DiskPlanner.planEFI(LiveDisks()) {
    case .success(let plan):
        print("PLAN: \(plan)")
        return plan
    case .failure(let err):
        log("REFUSED: \(err)")
        return nil
    }
}

func sha256Tree(_ root: URL) -> [String: String] {
    var out: [String: String] = [:]
    let fm = FileManager.default
    guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
    for case let u as URL in e {
        guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
        let (rc, d) = run("/usr/bin/shasum", ["-a", "256", u.path])
        guard rc == 0 else { continue }
        let rel = String(u.path.dropFirst(root.path.count))
        out[rel] = String(decoding: d, as: UTF8.self).split(separator: " ").first.map(String.init)
    }
    return out
}

func installEFI(source: String, dryRun: Bool) -> Int32 {
    if checkHardware() != 0 { return 2 }
    guard let plan = planEFI() else { return 2 }
    let src = URL(fileURLWithPath: source).appendingPathComponent("EFI")
    guard FileManager.default.fileExists(atPath: src.appendingPathComponent("OC/OpenCore.efi").path),
          FileManager.default.fileExists(atPath: src.appendingPathComponent("BOOT/BOOTx64.efi").path) else {
        log("source \(src.path) is not an OpenCore EFI folder")
        return 1
    }
    if dryRun {
        print("DRY-RUN: would install \(src.path) to \(plan.efiPartition)")
        return 0
    }

    // Mount (remember whether it was already mounted)
    guard let pre = LiveDisks().info(plan.efiPartition) else { return 1 }
    let wasMounted = (pre["MountPoint"] as? String).map { !$0.isEmpty } ?? false
    if !wasMounted {
        let (rc, _) = run("/usr/sbin/diskutil", ["mount", plan.efiPartition])
        if rc != 0 { log("could not mount \(plan.efiPartition)"); return 1 }
    }
    defer { if !wasMounted { _ = run("/usr/sbin/diskutil", ["unmount", plan.efiPartition]) } }
    guard let post = LiveDisks().info(plan.efiPartition),
          let mp = post["MountPoint"] as? String, !mp.isEmpty else {
        log("EFI mount point unknown"); return 1
    }
    let fsType = (post["FilesystemType"] as? String) ?? ""
    if fsType != "msdos" { log("EFI partition filesystem is '\(fsType)', expected msdos (FAT32); refusing"); return 2 }

    let dstEFI = URL(fileURLWithPath: mp).appendingPathComponent("EFI")
    let fm = FileManager.default

    // Back up whatever is there now (Windows Boot Manager etc. is preserved:
    // only EFI/OC and EFI/BOOT are replaced).
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let backupDir = URL(fileURLWithPath: "/Library/SurfaceTouchMac/Backups")
    try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
    if fm.fileExists(atPath: dstEFI.path) {
        let zip = backupDir.appendingPathComponent("EFI-\(stamp).zip").path
        let (rc, _) = run("/usr/bin/ditto", ["-c", "-k", "--keepParent", dstEFI.path, zip])
        if rc != 0 { log("backup failed; refusing to overwrite"); return 1 }
        print("BACKUP: \(zip)")
    }

    for sub in ["OC", "BOOT"] {
        let from = src.appendingPathComponent(sub)
        let to = dstEFI.appendingPathComponent(sub)
        let staging = dstEFI.appendingPathComponent(sub + ".stm-new")
        try? fm.removeItem(at: staging)
        try? fm.createDirectory(at: dstEFI, withIntermediateDirectories: true)
        let (rc, _) = run("/usr/bin/ditto", ["--norsrc", "--noextattr", from.path, staging.path])
        if rc != 0 { log("copy of \(sub) failed"); try? fm.removeItem(at: staging); return 1 }
        // verify before swapping in
        if sha256Tree(from) != sha256Tree(staging) {
            log("verification of \(sub) failed; existing files left untouched")
            try? fm.removeItem(at: staging)
            return 1
        }
        try? fm.removeItem(at: to)
        do { try fm.moveItem(at: staging, to: to) } catch { log("swap of \(sub) failed: \(error)"); return 1 }
    }
    print("INSTALLED: OpenCore -> \(plan.efiPartition) (\(plan.wholeDisk))")
    return 0
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "check-hardware":
    exit(checkHardware())
case "plan-efi":
    exit(planEFI() == nil ? 2 : 0)
case "install-efi":
    guard let i = args.firstIndex(of: "--source"), i + 1 < args.count else {
        log("usage: stm-setup install-efi --source <dir> [--dry-run]"); exit(1)
    }
    exit(installEFI(source: args[i + 1], dryRun: args.contains("--dry-run")))
default:
    log("usage: stm-setup check-hardware | plan-efi | install-efi --source <dir> [--dry-run]")
    exit(1)
}
