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
    func testFingerLandingHidesTrackpadShows() {
        var p = PointerSourceTracker()
        XCTAssertEqual(p.moved(dx: 300, dy: 120, buttonDown: false, tablet: false), .touch)
        XCTAssertNil(p.moved(dx: 2, dy: 1, buttonDown: true, tablet: false))   // touch drag keeps hidden
        XCTAssertNil(p.moved(dx: 2, dy: 1, buttonDown: false, tablet: false))
        XCTAssertNil(p.moved(dx: 2, dy: 1, buttonDown: false, tablet: false))
        XCTAssertEqual(p.moved(dx: 1, dy: 1, buttonDown: false, tablet: false), .pointer)
    }

    func testTabletSubtypeIsTouch() {
        var p = PointerSourceTracker()
        XCTAssertEqual(p.moved(dx: 1, dy: 0, buttonDown: false, tablet: true), .touch)
        XCTAssertNil(p.moved(dx: 1, dy: 0, buttonDown: false, tablet: true))
    }
}
