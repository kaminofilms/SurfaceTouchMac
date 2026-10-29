// SPDX-License-Identifier: MIT
// Pure keyboard state machine: decides what each key press produces.
// No AppKit / CoreGraphics so it can be unit-tested anywhere.

public enum Output: Equatable, Sendable {
    case text(String)
    case special(SpecialKey)
    case none
}

public struct KeyboardState: Sendable {
    public private(set) var layer: Layer = .letters
    public private(set) var shift = false       // one-shot
    public private(set) var capsLock = false
    public private(set) var hideRequested = false

    public init() {}

    public var uppercase: Bool { shift != capsLock }

    /// Label to draw for a key in the current state.
    public func displayLabel(for key: Key) -> String {
        if case .character(let normal, let shifted) = key.action {
            return uppercase ? shifted : normal
        }
        return key.label
    }

    /// Applies a key press. Returns what must be typed (if anything) and
    /// whether the layout needs to be redrawn.
    public mutating func press(_ key: Key) -> (output: Output, redraw: Bool) {
        hideRequested = false
        switch key.action {
        case .character(let normal, let shifted):
            let text = uppercase ? shifted : normal
            let wasShift = shift
            shift = false
            return (.text(text), wasShift)
        case .special(let s):
            return (.special(s), false)
        case .shift:
            shift.toggle()
            return (.none, true)
        case .capsLock:
            capsLock.toggle()
            shift = false
            return (.none, true)
        case .switchLayer:
            layer = layer == .letters ? .symbols : .letters
            shift = false
            return (.none, true)
        case .hide:
            hideRequested = true
            shift = false
            return (.none, false)
        }
    }

    public mutating func resetTransient() {
        shift = false
        layer = .letters
    }
}
