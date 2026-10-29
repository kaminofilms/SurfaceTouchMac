import XCTest
@testable import TouchKeyboardCore

final class KeyboardStateTests: XCTestCase {
    func key(_ label: String, _ layer: Layer = .letters) -> Key {
        Layouts.rows(for: layer).flatMap { $0 }.first { $0.label == label }!
    }

    func testRequiredKeysPresent() {
        let all = Layouts.letters.flatMap { $0 } + Layouts.symbols.flatMap { $0 }
        let actions = all.map(\.action)
        for s: SpecialKey in [.delete, .returnKey, .tab, .space, .left, .right, .up, .down, .escape] {
            XCTAssertTrue(actions.contains(.special(s)), "missing \(s)")
        }
        XCTAssertTrue(actions.contains(.shift))
        XCTAssertTrue(actions.contains(.capsLock))
        XCTAssertTrue(actions.contains(.hide))
        for c in "abcdefghijklmnopqrstuvwxyz0123456789" {
            XCTAssertTrue(Layouts.letters.flatMap { $0 }.contains { $0.label == String(c) }, "missing \(c)")
        }
        for c in "!@#$%^&*()-=[]\\;'`_+{}|:\"~<>" {
            XCTAssertTrue(Layouts.symbols.flatMap { $0 }.contains { $0.label == String(c) }, "missing symbol \(c)")
        }
    }

    func testLowercaseByDefault() {
        var s = KeyboardState()
        XCTAssertEqual(s.press(key("a")).output, .text("a"))
    }

    func testShiftIsOneShot() {
        var s = KeyboardState()
        _ = s.press(key("⇧"))
        XCTAssertEqual(s.displayLabel(for: key("a")), "A")
        XCTAssertEqual(s.press(key("a")).output, .text("A"))
        XCTAssertEqual(s.press(key("a")).output, .text("a"))
    }

    func testShiftedPunctuation() {
        var s = KeyboardState()
        _ = s.press(key("⇧"))
        XCTAssertEqual(s.press(key("/")).output, .text("?"))
        _ = s.press(key("⇧"))
        XCTAssertEqual(s.press(key("1")).output, .text("!"))
    }

    func testCapsLockPersists() {
        var s = KeyboardState()
        _ = s.press(key("caps"))
        XCTAssertEqual(s.press(key("q")).output, .text("Q"))
        XCTAssertEqual(s.press(key("w")).output, .text("W"))
        // shift while caps lock is on gives lowercase (like a hardware keyboard)
        _ = s.press(key("⇧"))
        XCTAssertEqual(s.press(key("e")).output, .text("e"))
        _ = s.press(key("caps"))
        XCTAssertEqual(s.press(key("r")).output, .text("r"))
    }

    func testSymbolsLayer() {
        var s = KeyboardState()
        _ = s.press(key("#+="))
        XCTAssertEqual(s.layer, .symbols)
        XCTAssertEqual(s.press(key("{", .symbols)).output, .text("{"))
        _ = s.press(key("abc", .symbols))
        XCTAssertEqual(s.layer, .letters)
    }

    func testSpecialKeys() {
        var s = KeyboardState()
        XCTAssertEqual(s.press(key("⌫")).output, .special(.delete))
        XCTAssertEqual(s.press(key("return")).output, .special(.returnKey))
        XCTAssertEqual(s.press(key("tab")).output, .special(.tab))
        XCTAssertEqual(s.press(key("↑")).output, .special(.up))
        XCTAssertEqual(s.press(key("space")).output, .special(.space))
    }

    func testHide() {
        var s = KeyboardState()
        _ = s.press(key("hide"))
        XCTAssertTrue(s.hideRequested)
        _ = s.press(key("a"))
        XCTAssertFalse(s.hideRequested)
    }

    func testRepeatingKeys() {
        XCTAssertTrue(key("⌫").repeats)
        XCTAssertTrue(key("←").repeats)
        XCTAssertFalse(key("a").repeats)
        XCTAssertFalse(key("return").repeats)
    }
}

final class TouchSequencerTests: XCTestCase {
    func testSimpleTap() {
        let q = TouchSequencer()
        XCTAssertEqual(q.handle(.down, at: 0), .began)
        XCTAssertEqual(q.handle(.up, at: 0.08), .ignored)
        XCTAssertEqual(q.flush(at: 0.30), .ended)
    }

    func testLongPressHandoverIsOneTouch() {
        // driver: left down ... (1 s) left up, right down immediately, right up later
        let q = TouchSequencer()
        XCTAssertEqual(q.handle(.down, at: 0), .began)
        XCTAssertEqual(q.handle(.up, at: 1.0), .ignored)
        XCTAssertEqual(q.handle(.down, at: 1.01), .continued)
        XCTAssertEqual(q.flush(at: 1.2), .ignored)          // still held
        XCTAssertEqual(q.handle(.up, at: 2.5), .ignored)
        XCTAssertEqual(q.flush(at: 2.7), .ended)
    }

    func testTwoQuickTapsAreTwoTouches() {
        let q = TouchSequencer(handoverWindow: 0.12)
        XCTAssertEqual(q.handle(.down, at: 0), .began)
        _ = q.handle(.up, at: 0.05)
        XCTAssertEqual(q.flush(at: 0.2), .ended)
        XCTAssertEqual(q.handle(.down, at: 0.25), .began)
    }

    func testDuplicateDownIgnored() {
        let q = TouchSequencer()
        XCTAssertEqual(q.handle(.down, at: 0), .began)
        XCTAssertEqual(q.handle(.down, at: 0.01), .ignored)
    }

    func testRepeatPolicy() {
        let p = RepeatPolicy()
        XCTAssertEqual(p.repeats(after: 0.2), 0)
        XCTAssertEqual(p.repeats(after: 0.45), 1)
        XCTAssertEqual(p.repeats(after: 0.45 + 0.07 * 10), 11)
    }
}

final class FocusClassifierTests: XCTestCase {
    func testNativeFields() {
        for r in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"] {
            XCTAssertEqual(FocusClassifier.classify(FocusInfo(role: r)), .text, r)
        }
    }

    func testPasswordField() {
        XCTAssertEqual(FocusClassifier.classify(FocusInfo(role: "AXTextField", subrole: "AXSecureTextField")), .text)
    }

    func testBrowserContentEditable() {
        let info = FocusInfo(role: "AXGroup", attributeNames: ["AXRole", "AXSelectedTextRange", "AXValue"])
        XCTAssertEqual(FocusClassifier.classify(info), .text)
        XCTAssertEqual(FocusClassifier.classify(FocusInfo(role: "AXGroup", isEditableFlag: true)), .text)
    }

    func testNonText() {
        XCTAssertEqual(FocusClassifier.classify(FocusInfo(role: "AXButton")), .notText)
        XCTAssertEqual(FocusClassifier.classify(FocusInfo(role: nil)), .notText)
        // read-only web page text exposes a selection range but is not editable
        XCTAssertEqual(FocusClassifier.classify(FocusInfo(role: "AXWebArea", attributeNames: ["AXSelectedTextRange"])), .notText)
        XCTAssertEqual(FocusClassifier.classify(FocusInfo(role: "AXStaticText", attributeNames: ["AXSelectedTextRange"])), .notText)
    }

    func testOwnPanel() {
        XCTAssertEqual(FocusClassifier.classify(FocusInfo(role: "AXButton", isOwnProcess: true)), .ownPanel)
    }

    func testHideDebounce() {
        var d = HideDebouncer()
        XCTAssertFalse(d.notText(now: 10, lastKeyPress: 9.5))   // typing grace
        XCTAssertFalse(d.notText(now: 12, lastKeyPress: 9.5))   // first miss
        XCTAssertTrue(d.notText(now: 12.5, lastKeyPress: 9.5))  // second miss
        d.text()
        XCTAssertFalse(d.notText(now: 13, lastKeyPress: 9.5))
    }
}

final class GeometryTests: XCTestCase {
    func testSurfacePro7Sizing() {
        // 2736x1824 at the default 2x scale = 1368x912 pt, minus menu bar
        let m = KeyboardGeometry.metrics(visibleWidth: 1368, visibleHeight: 887,
                                         maxUnits: Layouts.maxUnits(for: .letters), rows: 5)
        XCTAssertLessThanOrEqual(m.width, 1368)
        XCTAssertGreaterThanOrEqual(m.unit, 80)
        XCTAssertGreaterThanOrEqual(m.keyHeight, 44)
        XCTAssertLessThanOrEqual(m.height, 887 * 0.45)
    }

    func testMoreSpaceScaling() {
        // "More Space" scaling 1824x1216 pt: keys capped, still fits
        let m = KeyboardGeometry.metrics(visibleWidth: 1824, visibleHeight: 1190,
                                         maxUnits: Layouts.maxUnits(for: .letters), rows: 5)
        XCTAssertLessThanOrEqual(m.width, 1824)
        XCTAssertLessThanOrEqual(m.unit, KeyboardGeometry.maxKey)
    }

    func testPlacementAvoidsField() {
        let visible = Rect(x: 0, y: 0, width: 1368, height: 887)
        let (_, yFree) = KeyboardGeometry.placement(visible: visible, size: (1300, 330), field: Rect(x: 100, y: 600, width: 300, height: 30))
        XCTAssertEqual(yFree, 8)
        let (_, yMoved) = KeyboardGeometry.placement(visible: visible, size: (1300, 330), field: Rect(x: 100, y: 50, width: 300, height: 30))
        XCTAssertEqual(yMoved, 887 - 330 - 8)
    }

    func testAXConversion() {
        let r = KeyboardGeometry.axToAppKit(Rect(x: 10, y: 20, width: 100, height: 30), primaryScreenHeight: 900)
        XCTAssertEqual(r, Rect(x: 10, y: 850, width: 100, height: 30))
    }
}
