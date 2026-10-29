import Foundation
import XCTest
@testable import SurfaceSetupCore

struct FixtureDisks: DiskInfoSource {
    let data: [String: Any]
    init(_ name: String) throws {
        let url = Bundle.module.url(forResource: name, withExtension: "plist", subdirectory: "Fixtures")!
        data = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
    }
    func info(_ id: String) -> [String: Any]? { (data["info"] as? [String: Any])?[id] as? [String: Any] }
    func list(_ id: String) -> [String: Any]? { (data["list"] as? [String: Any])?[id] as? [String: Any] }
    func wholeDisks() -> [String] { data["wholeDisks"] as? [String] ?? [] }
}

final class DiskPlannerTests: XCTestCase {
    func plan(_ name: String) throws -> Result<EFIPlan, PlanError> {
        DiskPlanner.planEFI(try FixtureDisks(name))
    }

    func testNormalInternalSSDWithUSBAndSDAttached() throws {
        let r = try plan("normal")
        guard case .success(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.wholeDisk, "disk0")
        XCTAssertEqual(p.efiPartition, "disk0s1")
    }

    func testRenumberedDisksNeverAssumeDisk0() throws {
        let r = try plan("renumbered")
        guard case .success(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.wholeDisk, "disk3")
        XCTAssertEqual(p.efiPartition, "disk3s1")
    }

    func testDualBootKeepsSharedEFI() throws {
        let r = try plan("dual_boot")
        guard case .success(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.efiPartition, "disk0s1")
    }

    func testRefusesWhenBootedFromUSB() throws {
        XCTAssertEqual(try plan("booted_external"), .failure(.targetNotInternal("disk2")))
    }

    func testRefusesTwoInternalDisks() throws {
        XCTAssertEqual(try plan("two_internal"), .failure(.ambiguousInternalDisks(["disk0", "disk1"])))
    }

    func testRefusesMissingEFI() throws {
        XCTAssertEqual(try plan("no_efi"), .failure(.noEFIPartition("disk0")))
    }

    func testRefusesMultipleStores() throws {
        XCTAssertEqual(try plan("multi_store"), .failure(.multiplePhysicalStores(["disk0s2", "disk1s2"])))
    }

    func testRefusesVirtualDisk() throws {
        XCTAssertEqual(try plan("virtual_disk"), .failure(.targetNotPhysical("disk0")))
    }

    func testRefusesEFINotFirst() throws {
        XCTAssertEqual(try plan("efi_not_first"), .failure(.efiNotFirstPartition("disk0s2")))
    }
}

final class HardwareCheckTests: XCTestCase {
    let surface: Set<String> = ["SurfaceSerialHubDriver", "IntelPreciseTouchStylusDriver", "SurfaceManagementEngineDriver"]

    func testSurfacePro7i5() {
        XCTAssertEqual(HardwareCheck.evaluate(HardwareFacts(cpuBrand: "Intel(R) Core(TM) i5-1035G4 CPU @ 1.10GHz", ioClasses: surface)),
                       .surfacePro7(cpu: "i5-1035G4"))
    }

    func testRejectsPro7Plus() {
        guard case .rejected = HardwareCheck.evaluate(HardwareFacts(cpuBrand: "11th Gen Intel(R) Core(TM) i5-1135G7 @ 2.40GHz", ioClasses: surface)) else {
            return XCTFail("7+ accepted")
        }
    }

    func testRejectsI3() {
        guard case .rejected = HardwareCheck.evaluate(HardwareFacts(cpuBrand: "Intel(R) Core(TM) i3-1005G1 CPU @ 1.20GHz", ioClasses: surface)) else {
            return XCTFail("i3 accepted")
        }
    }

    func testRejectsWithoutSurfaceDrivers() {
        guard case .rejected = HardwareCheck.evaluate(HardwareFacts(cpuBrand: "Intel(R) Core(TM) i5-1035G4 CPU @ 1.10GHz", ioClasses: [])) else {
            return XCTFail("accepted without Surface drivers")
        }
    }

    func testRejectsOtherMachines() {
        guard case .rejected = HardwareCheck.evaluate(HardwareFacts(cpuBrand: "Apple M2", ioClasses: [])) else {
            return XCTFail("accepted Apple silicon")
        }
    }
}
