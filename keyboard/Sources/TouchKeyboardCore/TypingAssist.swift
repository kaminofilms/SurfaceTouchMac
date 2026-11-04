// SPDX-License-Identifier: MIT
// iPad-style typing helpers: auto-capitals, double-space full stop, the
// current word (for the suggestions bar) and accent alternatives.
//
// Privacy: only what *this keyboard* typed is tracked, in memory, and it is
// cleared whenever focus changes or the user taps elsewhere. Nothing is read
// from other apps, logged or stored. Everything is off in password fields.

import Foundation

public struct TypingAssist: Sendable {
    public var enabled = true                 // false in password fields
    public private(set) var word = ""         // letters of the word being typed
    private var tail = ""                     // last few characters typed (max 3)
    private var lastSpaceAt = -1000.0
    private var capNext = false

    public static let doubleSpaceWindow = 0.6

    public init() {}

    /// Should the next letter be a capital (shown as a lit Shift key)?
    public var shouldCapitalizeNext: Bool { enabled && capNext }

    /// New text field focused. `isEmpty` = the field has no characters (count
    /// only, from accessibility; the text itself is never read).
    public mutating func fieldFocused(isEmpty: Bool?, secure: Bool) {
        reset()
        enabled = !secure
        capNext = isEmpty == true
    }

    /// The user tapped somewhere else (cursor may have moved): forget context.
    public mutating func reset() {
        word = ""; tail = ""; capNext = false; lastSpaceAt = -1000
    }

    /// Text the keyboard is about to type. Returns what should actually be
    /// sent (double space -> ". ").
    public mutating func type(_ text: String, now: Double) -> [Output] {
        guard enabled else { return [.text(text)] }
        if text == " " {
            let prev = tail.last
            let beforePrev = tail.dropLast().last
            if prev == " ", now - lastSpaceAt <= Self.doubleSpaceWindow,
               let b = beforePrev, b.isLetter || b.isNumber {
                // replace the first space with ". "
                record(". ")
                lastSpaceAt = -1000
                word = ""
                capNext = true
                return [.special(.delete), .text(". ")]
            }
            lastSpaceAt = now
            word = ""
            record(" ")
            capNext = endsSentence(tail)
            return [.text(" ")]
        }
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "'" || ch == "’" { word.append(ch) } else { word = "" }
        }
        record(text)
        capNext = false
        return [.text(text)]
    }

    /// A special key was sent (return, tab, arrows, delete ...).
    public mutating func special(_ key: SpecialKey) {
        switch key {
        case .delete:
            if !word.isEmpty { word.removeLast() }
            if !tail.isEmpty { tail.removeLast() }
            capNext = false
        case .returnKey:
            word = ""; tail = ""; capNext = enabled
        case .space:
            break
        default:
            reset()
        }
    }

    /// Replace the word being typed with a suggestion (+ trailing space).
    public mutating func accept(_ suggestion: String) -> [Output] {
        guard enabled, !word.isEmpty else { return [] }
        var out = [Output](repeating: .special(.delete), count: word.count)
        out.append(.text(suggestion + " "))
        word = ""
        record(suggestion + " ")
        capNext = false
        return out
    }

    private mutating func record(_ s: String) {
        tail = String((tail + s).suffix(3))
    }

    private func endsSentence(_ t: String) -> Bool {
        // ". " "! " "? " (the space was just typed)
        guard t.count >= 2 else { return false }
        let c = t[t.index(t.endIndex, offsetBy: -2)]
        return c == "." || c == "!" || c == "?"
    }
}

/// Accent alternatives shown on a long press (like iPad).
public enum Accents {
    static let table: [String: [String]] = [
        "a": ["à", "á", "â", "ä", "æ", "ã", "å", "ā"],
        "c": ["ç", "ć", "č"],
        "e": ["è", "é", "ê", "ë", "ē", "ė", "ę"],
        "i": ["î", "ï", "í", "ī", "į", "ì"],
        "l": ["ł"],
        "n": ["ñ", "ń"],
        "o": ["ô", "ö", "ò", "ó", "œ", "ø", "ō", "õ"],
        "s": ["ß", "ś", "š"],
        "u": ["û", "ü", "ù", "ú", "ū"],
        "y": ["ÿ"],
        "z": ["ž", "ź", "ż"],
        "-": ["–", "—", "•"],
        "'": ["‘", "’"],
        "\"": ["“", "”", "„"],
        "?": ["¿"],
        "!": ["¡"],
        "$": ["€", "£", "¥", "₩", "₽"],
        ".": ["…"],
    ]

    /// Alternatives for a key's character, in the right case.
    public static func alternatives(for base: String, uppercase: Bool) -> [String] {
        guard let alts = table[base.lowercased()] else { return [] }
        return uppercase ? alts.map { $0.uppercased() } : alts
    }
}

/// Detects a swipe that starts at a screen edge, from scroll gestures.
/// Points are in AppKit screen coordinates (origin bottom-left).
public enum ScreenEdge: Equatable, Sendable { case top, bottom, left, right }

public struct EdgeSwipeDetector: Sendable {
    public var edgeZone = 22.0       // start this close to an edge (points)
    public var bottomZoneFraction = 0.07   // the Dock band (matches the touch driver)
    public var trigger = 70.0        // inward distance that fires the action
    public private(set) var edge: ScreenEdge?
    private var travel = 0.0
    public private(set) var fired = false

    public init() {}

    /// Scroll gesture began with the pointer at `p`. Returns true if it is an
    /// edge swipe (its scroll events should then be swallowed).
    public mutating func begin(at p: (Double, Double), screen: Rect, menuBarHeight: Double) -> Bool {
        travel = 0; fired = false; edge = nil
        let (x, y) = p
        if y >= screen.maxY - edgeZone - menuBarHeight && y <= screen.maxY { edge = .top }
        else if y <= screen.y + max(edgeZone, screen.height * bottomZoneFraction) { edge = .bottom }
        else if x <= screen.x + edgeZone { edge = .left }
        else if x >= screen.maxX - edgeZone { edge = .right }
        return edge != nil
    }

    /// Feed scroll deltas (any sign convention; only movement across the edge
    /// counts). Returns the edge once, when the swipe is long enough.
    public mutating func add(dx: Double, dy: Double) -> ScreenEdge? {
        guard let e = edge, !fired else { return nil }
        switch e {
        case .top, .bottom: travel += abs(dy)
        case .left, .right: travel += abs(dx)
        }
        if travel >= trigger { fired = true; return e }
        return nil
    }

    public mutating func end() { edge = nil; travel = 0 }
    public var active: Bool { edge != nil }
}

/// Decides whether pointer events come from the touchscreen (hide the pointer)
/// or from a trackpad/mouse (show it).
public struct PointerSourceTracker: Sendable {
    public enum Source: Equatable, Sendable { case touch, pointer }
    public private(set) var source: Source = .pointer
    public var jumpThreshold = 40.0   // a move this large in one event = finger landed
    public var showAfter = 3          // consecutive small moves (no button) = trackpad/mouse

    private var smallMoves = 0
    public init() {}

    /// `tablet` = the event carries tablet/digitizer data (subtype).
    /// Returns the new source if it changed.
    public mutating func moved(dx: Double, dy: Double, buttonDown: Bool, tablet: Bool) -> Source? {
        let jump = (dx * dx + dy * dy).squareRoot() >= jumpThreshold
        if tablet || jump {
            smallMoves = 0
            return set(.touch)
        }
        if buttonDown { return nil }        // drags/scrolls keep the current state
        smallMoves += 1
        if smallMoves >= showAfter { return set(.pointer) }
        return nil
    }

    private mutating func set(_ s: Source) -> Source? {
        if s == source { return nil }
        source = s
        return s
    }
}
