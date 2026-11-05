// SPDX-License-Identifier: MIT
// Pure keyboard state machine: decides what each key press produces.
// No AppKit / CoreGraphics so it can be unit-tested anywhere.

public enum Output: Equatable, Sendable {
    case text(String)
    case special(SpecialKey)
    /// A key with ⌃/⌥/⌘ (posted by key code, e.g. ⌘C)
    case shortcut(Shortcut)
    case none
}

public struct Shortcut: Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: Set<Modifier>
    public let shift: Bool
    public init(keyCode: UInt16, modifiers: Set<Modifier>, shift: Bool = false) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.shift = shift
    }
    public static let undo  = Shortcut(keyCode: 6, modifiers: [.command])
    public static let cut   = Shortcut(keyCode: 7, modifiers: [.command])
    public static let copy  = Shortcut(keyCode: 8, modifiers: [.command])
    public static let paste = Shortcut(keyCode: 9, modifiers: [.command])
}

public struct KeyboardState: Sendable {
    public private(set) var layer: Layer = .letters
    public private(set) var shift = false       // one-shot
    public private(set) var capsLock = false
    public private(set) var hideRequested = false
    /// ⌃ ⌥ ⌘ waiting for the next key
    public private(set) var modifiers: Set<Modifier> = []
    private var shiftIsAuto = false             // lit by auto-capitals, not by the user

    public init() {}

    public var uppercase: Bool { shift != capsLock }

    /// Whether a key should be drawn as latched (Shift, Caps Lock, ⌃ ⌥ ⌘).
    public func isLatched(_ key: Key) -> Bool {
        switch key.action {
        case .shift: return shift
        case .capsLock: return capsLock
        case .modifier(let m): return modifiers.contains(m)
        default: return false
        }
    }

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
            let userShift = shift && !shiftIsAuto
            shift = false
            shiftIsAuto = false
            if !modifiers.isEmpty {
                // shortcuts ignore Caps Lock and auto-capitals: ⌘A stays ⌘A,
                // ⇧ pressed by the user still counts (⌘⇧Z = redo)
                let mods = modifiers
                modifiers = []
                let keyText = userShift ? shifted : normal
                if let k = KeyCodes.lookup(keyText) {
                    return (.shortcut(Shortcut(keyCode: k.code, modifiers: mods, shift: k.shift)), true)
                }
                return (.text(text), true)          // no key for it (e.g. €): just type it
            }
            return (.text(text), wasShift)
        case .special(let s):
            if !modifiers.isEmpty {
                let mods = modifiers
                let sh = shift && !shiftIsAuto
                modifiers = []
                shift = false
                shiftIsAuto = false
                return (.shortcut(Shortcut(keyCode: s.rawValue, modifiers: mods, shift: sh)), true)
            }
            return (.special(s), false)
        case .modifier(let m):
            if modifiers.contains(m) { modifiers.remove(m) } else { modifiers.insert(m) }
            return (.none, true)
        case .shift:
            shift.toggle()
            shiftIsAuto = false
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
            modifiers = []
            return (.none, false)
        }
    }

    /// Auto-capitalisation: light the one-shot Shift (ignored while Caps Lock is on).
    public mutating func setAutoShift(_ on: Bool) {
        if !capsLock { shift = on; shiftIsAuto = on }
    }

    public mutating func resetTransient() {
        shift = false
        shiftIsAuto = false
        modifiers = []
        layer = .letters
    }
}
