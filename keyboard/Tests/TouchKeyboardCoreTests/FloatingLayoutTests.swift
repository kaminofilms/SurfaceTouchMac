import XCTest
@testable import TouchKeyboardCore

final class FloatingLayoutTests: XCTestCase {
    let screen = Rect(x: 0, y: 0, width: 1368, height: 887)   // Surface Pro 7 at 200%
    let units = Layouts.maxUnits(for: .letters)

    func testOpacityCycles() {
        var s = KeyboardSettings()
        var seen: [Double] = []
        for _ in 0..<5 { s.cycleOpacity(); seen.append(s.opacity) }
        XCTAssertEqual(seen, [0.85, 0.65, 0.45, 1.0, 0.85])
    }

    func testPersistenceRoundTrip() {
        var s = KeyboardSettings()
        s.mode = .floating; s.opacity = 0.65; s.floatX = 120; s.floatY = 300; s.floatWidth = 640
        XCTAssertEqual(KeyboardSettings.decode(s.encode()), s)
    }

    func testDecodeRejectsBadValues() {
        let s = KeyboardSettings.decode(["mode": "sideways", "opacity": "0.01", "floatWidth": "inf"])
        XCTAssertEqual(s.mode, .docked)
        XCTAssertEqual(s.opacity, 0.3)
        XCTAssertEqual(s.floatWidth, 760)
    }

    func testKeysScaleWithWidth() {
        let small = FloatingGeometry.metrics(width: 420, maxUnits: units, rows: 5)
        let big = FloatingGeometry.metrics(width: 1200, maxUnits: units, rows: 5)
        XCTAssertLessThan(small.unit, big.unit)
        XCTAssertGreaterThanOrEqual(small.keyHeight, 26)
        XCTAssertEqual(small.width, 420, accuracy: 0.5)
    }

    func testClampWidth() {
        XCTAssertEqual(FloatingGeometry.clampWidth(100, visible: screen), KeyboardSettings.minWidth)
        XCTAssertEqual(FloatingGeometry.clampWidth(5000, visible: screen), 1368)
    }

    func testClampOriginKeepsOnScreen() {
        let (x, y) = FloatingGeometry.clampOrigin(x: -500, y: 2000, size: (600, 250), visible: screen)
        XCTAssertEqual(x, 0); XCTAssertEqual(y, 887 - 250)
        let (x2, y2) = FloatingGeometry.clampOrigin(x: 1300, y: -40, size: (600, 250), visible: screen)
        XCTAssertEqual(x2, 1368 - 600); XCTAssertEqual(y2, 0)
    }

    func testResizeKeepsTopLeftAndFits() {
        let r = FloatingGeometry.resize(startWidth: 600, startTop: 700, startX: 100, dx: 200,
                                        maxUnits: units, rows: 5, visible: screen)
        XCTAssertEqual(r.width, 800, accuracy: 0.01)
        XCTAssertEqual(r.x, 100)
        let h = FloatingGeometry.metrics(width: 800, maxUnits: units, rows: 5).height
        XCTAssertEqual(r.y + h, 700, accuracy: 0.01)
        // cannot grow past the right edge
        let r2 = FloatingGeometry.resize(startWidth: 600, startTop: 700, startX: 900, dx: 2000,
                                         maxUnits: units, rows: 5, visible: screen)
        XCTAssertEqual(r2.width, 1368 - 900, accuracy: 0.01)
        // cannot shrink below the minimum
        let r3 = FloatingGeometry.resize(startWidth: 600, startTop: 700, startX: 100, dx: -900,
                                         maxUnits: units, rows: 5, visible: screen)
        XCTAssertEqual(r3.width, KeyboardSettings.minWidth)
    }
}
