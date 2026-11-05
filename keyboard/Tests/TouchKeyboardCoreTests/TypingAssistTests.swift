import XCTest
@testable import TouchKeyboardCore

final class TypingAssistTests: XCTestCase {
    func typeAll(_ a: inout TypingAssist, _ s: String, start: Double = 0) -> [Output] {
        var out: [Output] = []
        var t = start
        for ch in s { out += a.type(String(ch), now: t); t += 0.2 }
        return out
    }

    func testCapitalAtStartOfEmptyField() {
        var a = TypingAssist()
        a.fieldFocused(isEmpty: true, secure: false)
        XCTAssertTrue(a.shouldCapitalizeNext)
        _ = a.type("H", now: 0)
        XCTAssertFalse(a.shouldCapitalizeNext)
    }

    func testNoCapitalInNonEmptyOrUnknownField() {
        var a = TypingAssist()
        a.fieldFocused(isEmpty: false, secure: false)
        XCTAssertFalse(a.shouldCapitalizeNext)
        a.fieldFocused(isEmpty: nil, secure: false)
        XCTAssertFalse(a.shouldCapitalizeNext)
    }

    func testCapitalAfterSentence() {
        var a = TypingAssist()
        _ = typeAll(&a, "hi there.")
        XCTAssertFalse(a.shouldCapitalizeNext)
        _ = a.type(" ", now: 10)
        XCTAssertTrue(a.shouldCapitalizeNext)
        _ = typeAll(&a, "ok?", start: 11)
        _ = a.type(" ", now: 20)
        XCTAssertTrue(a.shouldCapitalizeNext)
    }

    func testDoubleSpaceFullStop() {
        var a = TypingAssist()
        _ = typeAll(&a, "hello")
        XCTAssertEqual(a.type(" ", now: 5.0), [.text(" ")])
        XCTAssertEqual(a.type(" ", now: 5.3), [.special(.delete), .text(". ")])
        XCTAssertTrue(a.shouldCapitalizeNext)
    }

    func testDoubleSpaceTooSlowOrAfterPunctuation() {
        var a = TypingAssist()
        _ = typeAll(&a, "hello")
        _ = a.type(" ", now: 5.0)
        XCTAssertEqual(a.type(" ", now: 6.0), [.text(" ")])    // too slow
        var b = TypingAssist()
        _ = typeAll(&b, "end.")
        _ = b.type(" ", now: 5.0)
        XCTAssertEqual(b.type(" ", now: 5.2), [.text(" ")])    // no ". " after "."
    }

    func testWordTracking() {
        var a = TypingAssist()
        _ = typeAll(&a, "good mor")
        XCTAssertEqual(a.word, "mor")
        a.special(.delete)
        XCTAssertEqual(a.word, "mo")
        _ = a.type(",", now: 9)
        XCTAssertEqual(a.word, "")
    }

    func testAcceptSuggestionReplacesWord() {
        var a = TypingAssist()
        _ = typeAll(&a, "tom")
        let out = a.accept("tomorrow")
        XCTAssertEqual(out, [.special(.delete), .special(.delete), .special(.delete), .text("tomorrow ")])
        XCTAssertEqual(a.word, "")
        var fresh = TypingAssist()
        XCTAssertEqual(fresh.accept("x"), [])                 // nothing typed: nothing replaced
    }

    func testPasswordFieldsAreUntouched() {
        var a = TypingAssist()
        a.fieldFocused(isEmpty: true, secure: true)
        XCTAssertFalse(a.shouldCapitalizeNext)
        _ = typeAll(&a, "abc")
        XCTAssertEqual(a.type(" ", now: 1), [.text(" ")])
        XCTAssertEqual(a.type(" ", now: 1.1), [.text(" ")])
        XCTAssertEqual(a.accept("abcdef"), [])
    }

    func testResetOnArrowsAndFocus() {
        var a = TypingAssist()
        _ = typeAll(&a, "wor")
        a.special(.left)
        XCTAssertEqual(a.word, "")
        _ = typeAll(&a, "ab")
        a.fieldFocused(isEmpty: false, secure: false)
        XCTAssertEqual(a.word, "")
    }

    func testAccents() {
        XCTAssertTrue(Accents.alternatives(for: "e", uppercase: false).contains("é"))
        XCTAssertTrue(Accents.alternatives(for: "E", uppercase: true).contains("É"))
        XCTAssertEqual(Accents.alternatives(for: "k", uppercase: false), [])
        XCTAssertTrue(Accents.alternatives(for: "$", uppercase: false).contains("€"))
    }
}

final class EdgeSwipeTests: XCTestCase {
    let screen = Rect(x: 0, y: 0, width: 1368, height: 912)

    func testTopEdgeSwipe() {
        var d = EdgeSwipeDetector()
        XCTAssertTrue(d.begin(at: (600, 905), screen: screen, menuBarHeight: 25))
        XCTAssertEqual(d.edge, .top)
        XCTAssertNil(d.add(dx: 0, dy: -30))
        XCTAssertEqual(d.add(dx: 2, dy: -45), .top)
        XCTAssertNil(d.add(dx: 0, dy: -100))            // fires once
    }

    func testSideAndBottomEdges() {
        var d = EdgeSwipeDetector()
        XCTAssertTrue(d.begin(at: (5, 400), screen: screen, menuBarHeight: 25)); XCTAssertEqual(d.edge, .left)
        XCTAssertEqual(d.add(dx: 80, dy: 0), .left)
        XCTAssertTrue(d.begin(at: (1360, 400), screen: screen, menuBarHeight: 25)); XCTAssertEqual(d.edge, .right)
        XCTAssertTrue(d.begin(at: (600, 10), screen: screen, menuBarHeight: 25)); XCTAssertEqual(d.edge, .bottom)
        XCTAssertNil(d.add(dx: 200, dy: 0))             // sideways movement doesn't count for bottom
    }

    func testSwipeUpFromAnywhereInDockBand() {
        var d = EdgeSwipeDetector()
        XCTAssertTrue(d.begin(at: (600, 55), screen: screen, menuBarHeight: 25))   // 912 * 7% = 63.8
        XCTAssertEqual(d.edge, .bottom)
        XCTAssertFalse(d.begin(at: (600, 80), screen: screen, menuBarHeight: 25))
    }

    func testMiddleIsNotAnEdge() {
        var d = EdgeSwipeDetector()
        XCTAssertFalse(d.begin(at: (600, 400), screen: screen, menuBarHeight: 25))
        XCTAssertFalse(d.active)
        XCTAssertNil(d.add(dx: 300, dy: 300))
    }
}

final class PointerSourceTests: XCTestCase {
    func testFingerTapsHideEvenWhenClose() {
        // typing on the on-screen keyboard: each tap = one small move + click
        var p = PointerSourceTracker()
        var t = 10.0
        XCTAssertEqual(p.moved(dx: 300, dy: 120, buttonDown: false, tablet: false, now: t), .touch)
        for _ in 0..<20 {
            t += 0.2
            XCTAssertNil(p.moved(dx: 25, dy: 3, buttonDown: false, tablet: false, now: t))
            XCTAssertNil(p.moved(dx: 0, dy: 0, buttonDown: true, tablet: false, now: t + 0.01))
        }
        XCTAssertEqual(p.source, .touch)
    }

    func testFingerTapAfterMouseHides() {
        var p = PointerSourceTracker()
        var t = 1.0
        for _ in 0..<6 { t += 0.016; _ = p.moved(dx: 2, dy: 1, buttonDown: false, tablet: false, now: t) }
        XCTAssertEqual(p.source, .pointer)
        // a finger tap a second later (one move then a click)
        XCTAssertNil(p.moved(dx: 10, dy: 5, buttonDown: false, tablet: false, now: t + 1))
        XCTAssertEqual(p.moved(dx: 0, dy: 0, buttonDown: true, tablet: false, now: t + 1.01), .touch)
    }

    func testMouseStreamShowsAndMouseClickKeepsIt() {
        var p = PointerSourceTracker()
        var t = 1.0
        _ = p.moved(dx: 300, dy: 0, buttonDown: false, tablet: false, now: t)
        XCTAssertEqual(p.source, .touch)
        var changed: PointerSourceTracker.Source?
        for _ in 0..<5 { t += 0.016; changed = p.moved(dx: 3, dy: 1, buttonDown: false, tablet: false, now: t) ?? changed }
        XCTAssertEqual(changed, .pointer)
        // click and drag right after moving: still the mouse
        for _ in 0..<30 { t += 0.016; XCTAssertNil(p.moved(dx: 2, dy: 0, buttonDown: true, tablet: false, now: t)) }
        XCTAssertEqual(p.source, .pointer)
    }

    func testTrackpadContactShowsPointer() {
        var p = PointerSourceTracker()
        _ = p.moved(dx: 300, dy: 0, buttonDown: false, tablet: false, now: 1)
        XCTAssertEqual(p.trackpadActivity(now: 2), .pointer)
        // tap-to-click on the trackpad right after: stays pointer
        XCTAssertNil(p.moved(dx: 0, dy: 0, buttonDown: true, tablet: false, now: 2.1))
        // a finger on the screen later
        XCTAssertEqual(p.moved(dx: 200, dy: 100, buttonDown: false, tablet: false, now: 5), .touch)
    }

    func testDockSlideDoesNotShowPointer() {
        var p = PointerSourceTracker()
        var t = 1.0
        _ = p.moved(dx: 300, dy: 0, buttonDown: false, tablet: false, now: t)
        for _ in 0..<40 { t += 0.008; XCTAssertNil(p.moved(dx: 3, dy: 0, buttonDown: false, tablet: false, now: t, inDockBand: true)) }
        XCTAssertEqual(p.source, .touch)
    }

    func testTabletSubtypeIsTouch() {
        var p = PointerSourceTracker()
        XCTAssertEqual(p.moved(dx: 1, dy: 0, buttonDown: false, tablet: true, now: 1), .touch)
        XCTAssertNil(p.moved(dx: 1, dy: 0, buttonDown: false, tablet: true, now: 1.01))
    }
}

final class MenuAlternatesTests: XCTestCase {
    func testAlternatesAreDropped() {
        XCTAssertTrue(MenuAlternates.repeatsPrevious("Restart", previous: "Restart…"))
        XCTAssertTrue(MenuAlternates.repeatsPrevious("Log Out Kamino Films", previous: "Log Out Kamino Films..."))
        XCTAssertFalse(MenuAlternates.repeatsPrevious("Shut Down…", previous: "Restart"))
        XCTAssertFalse(MenuAlternates.repeatsPrevious("", previous: ""))
        XCTAssertFalse(MenuAlternates.repeatsPrevious("Sleep", previous: nil))
    }
}
